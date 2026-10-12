# Failure, idempotency, concurrency and scale design

These guidelines treat failure, retries, concurrency, cost, trust and observability as design inputs, not as hardening added after the happy path works. The shared stance: assume every message arrives twice, every wait can hang, every list belongs to the largest tenant, and every caller may be wrong or hostile. Make the failure visible, the retry harmless and the bound explicit, then keep the code simple everywhere the volume does not demand more.

## Fail loud with typed errors

**Principle:** Throw a typed, domain-specific error when a contract breaks, catch only what you can recover from, and let one boundary decide what happens next.

**Why:** A default that papers over a broken invariant turns a visible bug into quiet data corruption that surfaces far away and much later. A blanket catch converts every unrelated failure, such as an outage, a coding error or a changed callee, into the one outcome the author had in mind; when that outcome is permissive it becomes a security hole. Typed error kinds let the API layer map statuses consistently and let telemetry group failures by real cause. The handler error helpers and the static-message rule are defined in `packages/server/hoxapp/docs/dev-guides/coding-rules.md` and `.claude/skills/hoxapp--create-handler/references/acl-and-errors.md`; this guideline adds when to throw, when to catch and where to stop.

**Smells:**
- A `?? []`, `?? new Date()` or `?? ''` filling a value that must always exist, especially one that feeds a key or identity.
- A `catch` or `.catch(() => fallback)` around a call with many failure modes, where the fallback grants access, returns `null` or reports "not found".
- Control flow that sniffs an error message string, or a wide `try` wrapping several steps when only one is meant to be tolerated.
- A catch that only logs and continues around a side effect whose failure matters, or a UI that shows success before the mutation resolved.
- A mapper that turns unknown external values into a default without logging the raw value.
- A bare `throw new Error(...)` or a generic cross-domain code like "invalid payload" in handler code.

**Do instead:**
- Throw with a message naming the broken assumption, and fix the producer upstream instead of patching the consumer. Make dispatch over variants exhaustive so the next variant fails immediately.
- Branch on a type guard for the one expected error kind and rethrow the rest. Shrink the `try` to the single call being tolerated.
- Wrap errors with context so the original cause, type and stack stay inspectable; let the outermost layer log, alert or exit once.
- Decide per guard whether it fails open or closed, and test that choice. Security and quality gates fail closed.
- Expose only deliberately mapped, machine-readable errors to external clients. Return expected business outcomes, such as unresolved ids, as structured fields, never inside a message string.

**Bad → good:**

**Bad:**
```typescript
async function findEnrollment(ctx: Ctx, userId: string, courseId: string) {
  try {
    return await enrollments.get(ctx, { userId, courseId });
  } catch {
    return null;
  }
}
```

**Good:**
```typescript
async function findEnrollment(ctx: Ctx, userId: string, courseId: string) {
  try {
    return await enrollments.get(ctx, { userId, courseId });
  } catch (error) {
    if (isNotFoundError(error)) return null;
    throw error;
  }
}
```

A database outage or a bug in the lookup now surfaces as an error instead of reading as "this user is not enrolled".

**Bad:**
```typescript
function toImportedUser(row: DirectoryRow): ImportedUser {
  return {
    identityKey: `${row.orgId}:${row.externalId ?? ''}`,
    department: row.department ?? 'Unassigned',
    startedAt: row.startDate ? new Date(row.startDate) : new Date(),
  };
}
```

**Good:**
```typescript
function toImportedUser(row: DirectoryRow): ImportedUser {
  if (!row.externalId) throw new DirectorySyncContractError('row has no external id');
  if (!row.startDate) throw new DirectorySyncContractError('row has no start date');
  return {
    identityKey: `${row.orgId}:${row.externalId}`,
    department: row.department ?? 'Unassigned',
    startedAt: new Date(row.startDate),
  };
}
```

A directory format change is noticed on the first row, instead of merging every id-less user into one identity. The department keeps its fallback because it is optional data the customer controls.

**When this does not apply:**
- Values a user controls and may legitimately leave empty need an explicit "not set" fallback, not a throw. Expected conditions with no corrective action need not even be logged.
- Code running outside the request context, such as startup or scripts, throws plain errors rather than faking a handler context to use the handler helpers.
- Fire-and-forget telemetry and other declared best-effort paths may swallow failures, but the contract must say best-effort.
- Throwing versus errors as values: request handlers throw typed errors that the API layer exposes, because returning error enums burdens every caller. Run-based subsystems such as automation engines record failures as data in the run result, because a throw escapes the recording. Both stand; stay consistent inside a subsystem and reuse a shared result helper instead of inventing one per feature.
- Fail loudly versus stay up: throw on a contract breach, but classify first. Legitimate states warn or stay silent, a valid all-disabled configuration must still boot, and strict validation goes where its failure has the smallest blast radius rather than in shared config that can crash-loop the fleet.
- Broad catch around a protective mechanism: a narrow catch is the default, because a broad one eats unrelated bugs. A rate limiter or kill switch must never block traffic because of its own failure, so it may catch broadly as long as it logs. Define a kill switch as "behave as if the feature did not exist".

## Every start has a stop, every wait a bound

**Principle:** Make every timeout cancel the work itself, give every wait a termination condition, bind state to the unit of work that owns it, and define start and stop together.

**Why:** Racing a promise against a timer stops the wait, not the work, so each retry or probe launches another copy and hung operations pile up with their sockets for the whole outage. External events sometimes never arrive, so unbounded polling spins forever and leaves state in limbo. Context captured by a long-lived object leaks cancellation and metadata across unrelated work. Teardown kept apart from setup drifts, and background work started before a fallible step leaks when boot fails.

**Smells:**
- `Promise.race` against a timer with the losing request left running, and the re-entry slot cleared on timeout.
- A recursive poll or a paging loop that ends only when a value appears or a cursor is strictly `undefined`, with no attempt or page cap.
- A long-lived listener, queue consumer or factory holding a request context created once at startup; a module-scope `Map` keyed by request id.
- A reset callback that discards "whatever is current" with no argument naming the failed instance, or a per-call timeout that closes a connection shared with other callers.
- A shutdown hook that starts a callback chain without awaiting it, independent drains awaited one by one, or a grace timer started inside the close callback.
- A component whose background polling starts implicitly on construction, or a timer rescheduled without clearing the previous one.

**Do instead:**
- Pass an abort signal or request-level timeout down to the socket. Keep the in-flight promise per key and report failure while it is pending instead of starting another.
- Pass the failed resource to reset and discard it only if it is still current; use a generation counter to invalidate pending creations.
- Add a deadline or attempt limit to every external wait, treat any nullish cursor as the end, define the limbo state explicitly and render a degraded path for it.
- Pass context per call or inject a factory; keep per-request data in storage that dies with the request; leave recycling of shared resources to their owner.
- Have each initialiser return its own teardown. Start background loops last, make stop idempotent and argument-free, and run shutdown as one awaited plan under one deadline.

**Bad → good:**

**Bad:**
```typescript
async function refreshTranslations(): Promise<boolean> {
  const timeout = new Promise<boolean>((resolve) =>
    setTimeout(() => resolve(false), 5_000),
  );
  return Promise.race([downloadTranslationBundle(), timeout]);
}
```

**Good:**
```typescript
let inFlight: Promise<boolean> | undefined;

async function refreshTranslations(): Promise<boolean> {
  inFlight ??= downloadTranslationBundle({ signal: AbortSignal.timeout(5_000) })
    .catch(() => false)
    .finally(() => { inFlight = undefined; });
  return inFlight;
}
```

The abort signal releases the socket when time runs out, and concurrent triggers share one download instead of stacking hung copies.

**Bad:**
```typescript
class DigestScheduler {
  constructor(private readonly mailer: Mailer) {
    this.timer = setInterval(() => this.flush(), 60_000);
  }
  async stop(mailer: Mailer) {
    clearInterval(this.timer);
    await mailer.close();
  }
}
```

**Good:**
```typescript
class DigestScheduler {
  private timer?: NodeJS.Timeout;
  constructor(private readonly mailer: Mailer) {}
  start() {
    this.timer ??= setInterval(() => this.flush(), 60_000);
  }
  async stop() {
    if (this.timer) clearInterval(this.timer);
    this.timer = undefined;
    await this.flush();
    await this.mailer.close();
  }
}
```

Construction has no side effects, start and stop live together, stop is safe to call twice, and pending work drains before the client closes.

**When this does not apply:**
- Bounded, transient overlap of idle resources is fine when waiting for full idleness would never converge under sustained load.
- Shutdown order versus concurrency: order is required between dependent stages, such as draining consumers before closing their client. Independent drains start concurrently and are awaited together under one overall deadline, so they do not eat each other's budget.
- Awaiting a side effect versus keeping it off the critical path: skip awaiting bookkeeping writes the response does not depend on, for a faster response. Await any write a following step relies on, such as a redirect that reads the new state. If you do not await, decide where its failure becomes visible.

## Security is decided by the trusted side

**Principle:** Take access and identity facts from the source that can know them, make access decisions on the server, and validate every untrusted value before it reaches a privileged path.

**Why:** A frontend redirect or flag over data already returned is not access control, because the data is in the network tab and the query can be called directly. A caller-controlled flag or payload field turns a security decision into forgeable input, and a decision inferred from a missing value breaks silently when another path fills it. Values that end up as selector paths, proxy targets or roles become attack surface the moment any upstream path lets a user set them. Each extra component that handles plaintext secrets or personal data widens the blast radius of a leak.

**Smells:**
- The client hides fields or redirects away after the full record was returned, or duplicates role gating that the backend should own.
- An input type accepting a user or organisation id that the server then overrides from the identity, or a boolean letting callers skip a security lookup.
- A lookup used as live validation that reveals whether an account exists.
- A configurable free-text string used directly as a database selector key, proxy target or redirect destination.
- An anonymous entry point escalating to a system context before parsing its payload.
- A reader that trusts long-lived records written before a validation existed, or a decrypted secret passed through several layers before use.

**Do instead:**
- Shape the data in the resolver so restricted fields never leave the server; the client only chooses what navigation to show.
- Remove inputs the server knows better. Read identity from the authenticated context and decisions from the persisted record, not the request.
- Constrain externally or admin-settable values to an enum or allowlist, and validate on the server before any privilege escalation.
- Act on free-form input without telling the client whether it matched, as a magic-link flow does.
- Re-check safety invariants when reading durable data, and decrypt secrets immediately before the call that needs them.

**Bad → good:**

**Bad:**
```graphql
input AssignTrainingInput {
  organizationId: ID!
  assignedByUserId: ID!
  departmentId: ID!
  trainingId: ID!
}
```

**Good:**
```graphql
input AssignTrainingInput {
  departmentId: ID!
  trainingId: ID!
}
```

The organisation and the assigning user come from the authenticated context, so no caller can forge them and no server code has to remember to override them.

**Bad:**
```typescript
const IntegrationConfig = z.object({
  vendor: z.string(),
  userMatchField: z.string(),
});
// later, under an elevated context
users.find({ [config.userMatchField]: incoming.value });
```

**Good:**
```typescript
const IntegrationConfig = z.object({
  vendor: z.enum(['directory-a', 'directory-b']),
  userMatchField: z.enum(['emails.address', 'externalId']),
});
// later, under an elevated context
users.find({ [config.userMatchField]: incoming.value });
```

The selector path is an allowlist validated on save, so a stored value can no longer steer an elevated query into arbitrary fields.

**When this does not apply:**
- Server-side validation that reveals nothing costs some UX feedback. Accept that cost for anything touching other users' data.
- Client-side enforcement is acceptable where bypassing it is deliberate API abuse with no security or privacy impact.
- When tooling such as a shell step makes in-memory confinement of a secret impractical, write it to a scoped location and clean up on exit.

## Telemetry is a shared vocabulary

**Principle:** Use one canonical attribute per concept, log outcomes with a correlation handle, build low-cardinality metrics around questions, and keep personal data out.

**Why:** Attributes exist so anyone can filter and correlate across the system without knowing which feature emitted a line. Feature-prefixed duplicates, serialised blobs and unbounded lists fragment searches and inflate storage. Every metric label value multiplies time series, so per-entity identifiers make metrics expensive and slow. Log retention is not tied to each customer's data retention, so personal data in logs cannot be deleted reliably. The attribute-setter style and static error messages are set out in `packages/server/hoxapp/docs/dev-guides/coding-rules.md`; this guideline adds what goes into the vocabulary and what stays out.

**Smells:**
- A new feature-prefixed attribute whose value is an identity that already has a canonical attribute.
- An attribute holding stringified JSON, an unbounded id list, an email or raw free text from a third party.
- Identifiers interpolated into a message, or each throw in a handler carrying a different ad-hoc subset of identifying attributes.
- An info log at every iteration of a hot loop, or a batch job that logs nothing when it fails or finishes.
- A periodic loop logging the same unchanged error every tick.
- A metric labelled by organisation, user or task signature, many histogram buckets with no stated threshold, or a new metric duplicating an existing one for one more callee.

**Do instead:**
- Reuse the canonical attribute and let the handler or domain context say which feature emitted it. Map new needs onto existing names or standard semantic conventions first.
- Define the identifying attribute set once per unit of work and attach it to every log and error from it.
- Emit one structured completion log per unit of work with its counts and measurements, and log persistent conditions only when they change.
- Label metrics by bounded values you control, put buckets at operational thresholds, prefer ratios, and route per-entity questions to logs or analytics.
- Log internal ids instead of personal values, attach event envelopes rather than payloads to traces, and strip anything PII-named centrally.

**Bad → good:**

**Bad:**
```typescript
for (const user of batch) {
  logger.info(ctx, `Reminder sent to ${user.email}`, {
    reminderUserEmail: user.email,
    reminderPayload: JSON.stringify(reminder),
  });
}
```

**Good:**
```typescript
const result = await sendReminders(batch);
logger.info(
  ctx,
  'Reminder batch finished',
  withOrganizationId(organizationId),
  withSentCount(result.sent),
  withFailedCount(result.failed),
);
```

One line per batch carries the counts under shared attribute names, and no email or payload ends up in log storage.

**Bad:**
```typescript
const sendDuration = new Histogram({
  name: 'reminder_send_seconds',
  labelNames: ['organization_id', 'template_id'],
  buckets: [0.01, 0.02, 0.05, 0.1, 0.2, 0.3, 0.5, 0.75, 1, 1.5, 2, 3, 5, 10],
});
```

**Good:**
```typescript
const sendDuration = new Histogram({
  name: 'reminder_send_seconds',
  labelNames: ['channel'],
  buckets: [0.1, 0.5, 2, 10],
});
```

The series count no longer grows with tenants, and the buckets answer the question operators actually ask: are sends under the latency target.

**When this does not apply:**
- Call-site identifiers with no logic behind them can stay as inline literals. Pass them into shared operations so lines correlate, but do not move them into shared constants.
- Emit metrics from the job that already owns the work instead of building a new pipeline to inspect its output; generic job-success monitoring covers "did it run".

## Weigh cost by call frequency

**Principle:** Let how often a path runs decide how much to optimise it: batch and cache hot paths explicitly, and keep rare paths simple and correctly layered.

**Why:** Work added to a per-event, per-request or per-row path multiplies by volume, so hidden lookups and repeated setup there become real cost. One query per row, awaits inside nested loops and one mutation per entity scale latency with input size. On rare admin or error paths, saving a query is not worth bypassing the data layer or bending a data shape. A cache hidden inside a shared handler silently gives every caller stale data.

**Smells:**
- A feature-flag or organisation lookup on every tracked event, or a dynamic import repeated on every call.
- A resolver field on a paginated list that issues its own query per row, or an `await` inside a nested loop.
- A client mapping over entities and firing one mutation each, or a mutation followed by a refetch of what it could have returned.
- Independent fetches run one after another, or an independent query gated on another query's loading state.
- A TTL cache wired into a generic store handler, or a memo keyed on only part of its inputs.
- A layering shortcut justified by efficiency on an operation that runs a few times a day.

**Do instead:**
- Ask how often the path runs before optimising. Defer checks until they decide something and prefer cheap count queries.
- Collect keys first, then fetch once in a batch or in parallel. Offer list-of-ids inputs for bulk operations, and accept lists on hot wire contracts from the start.
- Return the updated entity with its id so client caches update without a refetch.
- Keep shared handlers uncached; add a separately named cached helper at the hot call site, keyed on every input that affects the result.
- Do back-of-the-envelope throughput math against quotas and fixed costs before picking a scaling pattern; start limits small and raise on evidence.

**Bad → good:**

**Bad:**
```typescript
const resolvers = {
  Department: {
    completedQuestCount: (dept: Department, _: unknown, ctx: Ctx) =>
      ctx.db.questCompletions.countDocuments({ departmentId: dept.id }),
  },
};
```

**Good:**
```typescript
const resolvers = {
  Department: {
    completedQuestCount: (dept: Department, _: unknown, ctx: Ctx) =>
      ctx.loaders.completedQuestCountByDepartment.load(dept.id),
  },
};
```

A page of departments costs one grouped count query instead of one query per row.

**Bad:**
```typescript
export async function getOrgSettings(ctx: Ctx, orgId: string) {
  return settingsCache.getOrLoad(orgId, () => ctx.db.orgSettings.findOne({ orgId }));
}
```

**Good:**
```typescript
export async function getOrgSettings(ctx: Ctx, orgId: string) {
  return ctx.db.orgSettings.findOne({ orgId });
}

export async function getOrgSettingsMaybeStale(ctx: Ctx, orgId: string) {
  return settingsCache.getOrLoad(orgId, () => getOrgSettings(ctx, orgId));
}
```

Every caller of the plain read can trust it is fresh, and the hot path's name says it may be stale.

**When this does not apply:**
- Optimising versus keeping it simple: hot paths must avoid per-call lookups. On rare admin or error paths, extra queries and simpler layering win; call frequency decides.
- Batching small bounded writes: batch when the count grows with input size. For a small fixed cap on one pooled connection, sequential calls are simpler and batching code is premature.
- Cache inside a shared handler behind an opt-in flag versus a separate helper: both keep the default fresh, but prefer the separate, explicitly named helper because the staleness is then visible at the call site.
- Prefer staged rollouts over adding a per-call flag check to a hot path.

## At-least-once idempotent consumers

**Principle:** Treat every message and task as delivered at least once: claim atomically before any side effect, acknowledge only after the work resolved, derive dedup keys deterministically, and classify failures before retrying.

**Why:** Acking before the handler finishes turns a crash into silent loss, so at-least-once delivery with idempotent consumers is the reliable default. Redelivery then repeats whatever already ran: effects started alongside the unique-key insert, or a send whose report step failed, happen again. A decision that reads "everything since the last finding" sees a different window on every replay, so backfills disagree with live runs. Retrying errors that cannot recover wastes budget and floods logs, while dropping transient failures leaves state permanently inconsistent.

**Smells:**
- An ack issued right after firing the handler, without awaiting it.
- A unique-key insert run in `Promise.all` together with the effects it is meant to guard.
- A side effect and its outcome report in the same message handler, so a report failure redelivers the effect.
- A history query bounded only below, or a dedup key derived from the trigger alone and shared across processors.
- A catch that logs a failed secondary effect and moves on, or a recovery task that runs exactly once.
- A retry wrapper with no should-retry predicate, wrapped around a call that already retries, or one failure path for malformed messages and transient errors.

**Do instead:**
- Await the handler and ack on resolution. Parse the wire message at the edge so poison messages go to a dead-letter path and transient failures are retried.
- Run the idempotency claim first and alone; start effects only after it wins. Publish the outcome to a separate topic and report from its own subscriber.
- Bound history at the trigger's timestamp inclusively, build the dedup key from the trigger and the processor, and use one window convention for every processor.
- Hand intermittently failing secondary effects to the durable task system with self-rescheduling backoff in explicit buckets with jitter.
- Test repeat delivery for every consumer and task key: deliver the same message twice and assert one effect.

**Bad → good:**

**Bad:**
```typescript
async function onQuestCompleted(msg: QuestCompletedMessage) {
  await Promise.all([
    badgeAwards.insertOne({ _id: `${msg.userId}:${msg.questId}` }),
    badges.grant(msg.userId, msg.badgeId),
    push.notify(msg.userId, 'badge-earned'),
  ]);
}
```

**Good:**
```typescript
async function onQuestCompleted(msg: QuestCompletedMessage) {
  const claimed = await badgeAwards.insertIfAbsent({ _id: `${msg.userId}:${msg.questId}` });
  if (!claimed) return;
  await badges.grant(msg.userId, msg.badgeId);
  await awardedTopic.publish({ userId: msg.userId, badgeId: msg.badgeId });
}
```

A redelivered message loses the claim and grants nothing twice, and a failing notification is retried by its own subscriber without touching the award.

**Bad:**
```typescript
async function evaluateRepeatClicker(trigger: ClickEvent) {
  const since = await lastFindingTime(trigger.userId);
  const clicks = await clicksBetween(trigger.userId, since, new Date());
  return clicks.length >= 3 ? finding(`repeat:${trigger.userId}`) : null;
}
```

**Good:**
```typescript
async function evaluateRepeatClicker(trigger: ClickEvent) {
  const since = await lastFindingTime(trigger.userId, trigger.at);
  const clicks = await clicksBetween(trigger.userId, since, trigger.at, { inclusive: true });
  return clicks.length >= 3 ? finding(`repeat-clicker:${trigger.id}`) : null;
}
```

Replaying yesterday's trigger sees exactly yesterday's window, so retries and backfills produce the same finding and the same key.

**When this does not apply:**
- A window between a won claim and a later failing step may be left open on purpose until continuing past a duplicate is safe. Document the window and its consequence.
- Reading past a batch boundary to keep timestamp ties together costs some efficiency; correctness wins.
- A request path must not wait on the task system for completion. Shape the API around "accepted and scheduled" so the caller's budget does not depend on async work.
- When retrying would clash with already persisted state, recover in place or ack, rather than redelivering forever.

## Bound cardinality, isolate per item

**Principle:** Design every collection for the largest tenant: page, limit and filter in the query, fan heavy work out in small units, and report bulk outcomes per item.

**Why:** Lists that are small in development hold thousands of rows at large tenants, and a design that loads or renders them all fails late, in production. Loading candidates and deciding in memory pays for rows that are thrown away, so cost grows with the dataset rather than with the answer. A request that loops over hundreds of entities can time out and gives the client no progress. If one malformed item fails a whole batch while write errors are reported per item, the behaviour is unpredictable and one bad id blocks every valid one. Expensive or abuse-prone operations also need handler-level rate limits; the layering and where to add them is described in `packages/server/hoxratelimit/AGENTS.md`.

**Smells:**
- A picker, dropdown or table that loads every entity of a tenant, or a list query with no maximum page size.
- A first sync with no cursor that pulls the whole history, or a function receiving the full set to keep instead of the delta to act on.
- A `find` followed by an in-memory filter or sort the selector could express, or documents fetched only to test existence.
- A mutation that runs a per-user computation over a whole organisation inside the request.
- A bulk signature returning per-item results plus a separate batch-level error, or `Promise.all` over independent per-tenant work.
- A list endpoint that fails the whole page on one unrepresentable record.

**Do instead:**
- Ask "how many at the largest tenant?" for every collection. Use server-side search and pagination, cap page sizes, and give first syncs a default lookback with backfill as a separate concern.
- Move conditions into the selector and sorts into the query; use count or existence queries; pass the delta, not the full set.
- Enqueue background tasks, one per entity, submitted in bulk, and let the client follow progress.
- Collect every failure class into one per-item result list and drop the whole-call error. Use `allSettled` or per-iteration isolation for independent work.
- Skip and log malformed records in collection reads, but surface the error for single-item reads. Load code and dependent data only when the logic uses them.

**Bad → good:**

**Bad:**
```typescript
type BulkTagResult = {
  error?: string;
  items: { id: string; ok: boolean }[];
};

async function tagExtensions(ids: string[], tag: string): Promise<BulkTagResult> {
  const parsed = ids.map(parseExtensionId);
  if (parsed.some((p) => !p.valid)) return { error: 'invalid id', items: [] };
  return { items: await writeTags(parsed, tag) };
}
```

**Good:**
```typescript
type BulkTagResult = {
  items: { id: string; ok: boolean; reason?: 'invalid-id' | 'write-failed' }[];
};

async function tagExtensions(ids: string[], tag: string): Promise<BulkTagResult> {
  const parsed = ids.map(parseExtensionId);
  const invalid = parsed.filter((p) => !p.valid).map((p) => ({ id: p.raw, ok: false, reason: 'invalid-id' as const }));
  const written = await writeTags(parsed.filter((p) => p.valid), tag);
  return { items: [...invalid, ...written] };
}
```

One bad id no longer blocks the valid ones, and the caller handles every outcome in one loop.

**Bad:**
```typescript
const reports = await db.userReports.find({ orgId }).toArray();
const open = reports
  .filter((r) => r.state === 'open' && r.severity === 'high')
  .sort((a, b) => +b.reportedAt - +a.reportedAt)
  .slice(0, PAGE_SIZE);
```

**Good:**
```typescript
const open = await db.userReports
  .find({ orgId, state: 'open', severity: 'high' })
  .sort({ reportedAt: -1 })
  .limit(PAGE_SIZE)
  .toArray();
```

The cost follows the page the user sees, not the tenant's whole report history, and an index can serve it.

**When this does not apply:**
- Default limits versus correct aggregates: put a maximum page size on row lists from the start, but do not truncate grouped aggregates, because cut-off groups produce wrong totals. Limit aggregates only when the client paginates them.
- One big task versus many small tasks: small per-entity units bound memory and isolate failures, while per-task overhead pushes toward batches. Use many small units, submitted in bulk.
- Database versus stateless service for shaping results: filtering and aggregation that shrink the result belong in the database. Pure reshaping of an already small result may stay in the service, which scales more easily than the shared database. This is not fully settled.
- Fail fast versus isolate: isolate when items are independent. When later calls have side effects that must not happen after a failure, run in series and stop at the first error. Decide the abort semantics of a generic multi-target operation from concrete use cases.
- For tiny, bounded sets, inline work in the request is acceptable.

## Atomic check-then-act

**Principle:** Put the guard of every check-then-act inside the write itself, order multi-step writes so a retry can recover, and use transactions only when nothing else gives the guarantee.

**Why:** Overlapping runs, parallel writers and retries all pass a read-then-write check together, then overwrite each other or both perform the action. A transaction does not help unless the database enforces the precondition at commit. Rebuilding a whole array from a stale read loses concurrent edits. A crash between two dependent writes leaves hidden permanent inconsistency that later syncs never repair. Cross-collection transactions cost locks and performance and tie data to co-located storage.

**Smells:**
- An `if` over a freshly read document followed by an update with no condition in its selector.
- A whole embedded array or set rewritten from memory, or a toggle mutation that flips what it read.
- A precondition check inside a transaction presented as race-safe, or an update-then-insert-then-update chain to resolve a conflict.
- A status transition selector that excludes fewer states than the invariant promises.
- A resource created first and linked to its owner afterwards, so a failed link strands it and blocks retries.
- All items moved to "pending" up front with their tasks submitted later in batches, or `Promise.all` over queries sharing one transaction.

**Do instead:**
- Move the condition into the update selector, use atomic per-element operators, or win a unique claim or expiring lease from one authority.
- Expose add and remove deltas or a set-to-value input instead of full replacement or toggle.
- Let only the participant that wins the decisive write update derived fields.
- Write the claim before creating the resource, give each attempt its own immutable path, and interleave state transitions with task submission per batch.
- Keep steps that must agree in one transaction with sequential queries; otherwise use the other domain's handlers and design for eventual consistency.

**Bad → good:**

**Bad:**
```typescript
async function upsertException(policyId: string, exception: PolicyException) {
  const policy = await db.policies.findOne({ _id: policyId });
  const exceptions = (policy?.exceptions ?? []).filter((e) => e.id !== exception.id);
  exceptions.push(exception);
  await db.policies.updateOne({ _id: policyId }, { $set: { exceptions } });
}
```

**Good:**
```typescript
async function upsertException(policyId: string, exception: PolicyException) {
  const { matchedCount } = await db.policies.updateOne(
    { _id: policyId, 'exceptions.id': exception.id },
    { $set: { 'exceptions.$': exception } },
  );
  if (matchedCount === 1) return;
  await db.policies.updateOne(
    { _id: policyId, 'exceptions.id': { $ne: exception.id } },
    { $push: { exceptions: exception } },
  );
}
```

Each write touches only its own element and carries its guard in the selector, so two admins editing exceptions at once never erase each other's change or add a duplicate.

**Bad:**
```typescript
async function completeReport(reportId: string) {
  const report = await db.reports.findOne({ _id: reportId });
  if (report?.status !== 'processing') return false;
  await db.reports.updateOne({ _id: reportId }, { $set: { status: 'completed' } });
  return true;
}
```

**Good:**
```typescript
async function completeReport(reportId: string) {
  const { modifiedCount } = await db.reports.updateOne(
    { _id: reportId, status: 'processing' },
    { $set: { status: 'completed' } },
  );
  return modifiedCount === 1;
}
```

Only one concurrent caller can win the transition, and the return value tells it whether it did.

**When this does not apply:**
- Strict atomicity versus pragmatic guards: high-parallelism paths need atomic writes. For rarely invoked admin operations a read-modify-write is acceptable, and a short lock check combined with idempotent downstream tasks can replace a long-held lock. Match the guarantee to real call frequency and to whether downstream idempotency absorbs duplicates.
- Cross-collection transactions: they buy a consistency guarantee or audit identity cheaply, but cost locks, bypass collection-level abstractions and block splitting data onto separate clusters. This is disputed; the default is to call the other domain's handlers without a transaction, and to document read and write concerns and locking impact if one stays.
- Validate before side effects versus keep shapes: checking invariants before any effectful start is the principle. Reshaping a shared type to make that possible is not always worth it, and a narrow, alerted race window can be preferable to storing doomed records.
- Per-attempt resource paths leave an orphaned object for the losing attempt; that cost is accepted as cheap.
- When the framework cannot express the atomic update, write directly to the database and say why in the change description.
