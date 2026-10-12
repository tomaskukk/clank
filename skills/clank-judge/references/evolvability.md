# Evolvability: rollout, migration and change

These guidelines are about how a design copes with the next change rather than the current one. New variants arrive, deploys roll out piece by piece, stored data outlives the code that wrote it, and old paths need retiring. The shared stance is that every intermediate state must work. Adding a case should be one edit that the compiler checks. Removing something is only done when no data, client or name still points at it.

## Derive variant sets from one source

**Principle:** Keep each set of variants in one registry or schema, and derive every other list, enum, mapping and type from it.

**Why:** A hand-maintained list that must be extended for every new variant goes stale without failing. The new variant is skipped, misrouted or left untested, and nobody notices until data is wrong. When per-variant knowledge sits in one registration point, adding a variant is one edit. Parallel definitions joined by mappers can no longer drift apart.

**Smells:**
- A string array of identifiers decides routing, permissions, retries or which events are published.
- The same set of variants is spelled out in a GraphQL enum, a resolver map, a frontend label table and a test.
- A reset, copy or export function names by hand which collections or fields it touches.
- A constant such as a maximum count or an ordering map sits beside the data that already defines it.
- A comment says "keep in sync with" another file, or a config value is duplicated across manifests.
- Generated output is hand-edited, or a generator change regenerates only one consumer.

**Do instead:**
- Register each variant once in a typed config object that holds everything the system needs to know about it. Derive unions, enums, allowlists and UI options from that object.
- Where a mapping must cover every member, type it as an exhaustive record so a new member is a compile error until someone decides.
- Branch on every variant explicitly and fail on the unknown case instead of falling through.
- Treat generated files as output. Change the generator or the schema, regenerate every consumer in the same change, and let CI regenerate and fail on a diff.
- If a duplicate cannot be removed yet, back it with a drift test and a ticket.

The automation node registry is the repo's reference instance of this pattern, and `packages/server/hoxapp/imports/server/domains/percolator/CLAUDE.md` describes how its enum, seed data and availability checks derive from it.

**Bad:**

```typescript
type Channel = 'email' | 'slack' | 'teams';

const RETRYABLE_CHANNELS: Channel[] = ['email', 'slack'];

const channelLabels: Partial<Record<Channel, string>> = {
  email: 'Email',
  slack: 'Slack',
};

const MAX_CHANNELS = 3;
```

**Good:**

```typescript
const channelRegistry = {
  email: { label: 'Email', retryable: true },
  slack: { label: 'Slack', retryable: true },
  teams: { label: 'Microsoft Teams', retryable: false },
} as const satisfies Record<string, { label: string; retryable: boolean }>;

type Channel = keyof typeof channelRegistry;

const retryableChannels = (Object.keys(channelRegistry) as Channel[]).filter(
  channel => channelRegistry[channel].retryable
);
const maxChannels = Object.keys(channelRegistry).length;
```

A new channel is one entry, and it cannot be added without a label and a retry decision.

**Bad:**

```typescript
async function resetDemoOrganization(organizationId: string) {
  await quests.deleteMany({ organizationId });
  await reports.deleteMany({ organizationId });
  // a collection added next quarter is silently kept
}
```

**Good:**

```typescript
const demoResetPolicy: Record<OrganizationCollection, 'wipe' | 'keep'> = {
  quests: 'wipe',
  reports: 'wipe',
  departments: 'keep',
};

async function resetDemoOrganization(organizationId: string) {
  for (const [name, policy] of Object.entries(demoResetPolicy)) {
    if (policy === 'wipe') await collectionByName(name).deleteMany({ organizationId });
  }
}
```

A new organization collection fails typecheck here until its author says whether a reset wipes it.

**When this does not apply:**
- A subset that genuinely diverges from the source may be listed separately, with a note saying why it differs.
- Lists that are open-ended, or where omitting a member is harmless, do not need an exhaustive guard.
- Deriving from a naming convention only works when the convention is enforced. Otherwise it fails silently in a new way.
- Deriving across build boundaries can be expensive. A drift test that fails on mismatch is the accepted fallback.
- Things a schema language cannot express, such as partial indexes, stay hand-written beside the generated output with a note.

## One mechanism per recurring concern

**Principle:** Build a new case on the mechanism that already handles its concern instead of adding a second, parallel way.

**Why:** Two ways of doing the same thing split every future change. Fixes land in one path, and cross-cutting rules such as access checks, rate limits, auditing and error reporting are applied in one and missed in the other. The first ad-hoc mechanism also becomes the pattern: the second and third features copy it, and the system ends up with several incompatible versions. Joining the existing mechanism gives the new case those guarantees for free.

**Smells:**
- A new server, router, script or client factory doing what a shared one already does, added beside it.
- A feature registers its own route, flag or build step while its siblings go through a shared family.
- A general concern such as a schedule, a change history or overload handling is nested inside one feature's settings.
- Cross-cutting behaviour is hand-wired at one call site instead of flowing through the shared base.
- A handler bypasses a core primitive because the primitive lacks one capability.

**Do instead:**
- Find the sibling that already solves the concern and plug in, extending it if needed.
- Model a recurring concern generically, for example task type plus schedule, and expose per-feature views at the API layer.
- When the core primitive lacks a capability, add it there rather than working around it.
- If you are replacing the old mechanism, state the migration plan and delete the old path once the new one covers every use.

**Bad:**

```typescript
const ReportSettings = z.object({
  organizationId: z.string(),
  recipients: z.array(z.string()),
  digestSchedule: z.object({
    cron: z.string(),
    timezone: z.string(),
    lastRunAt: z.date().optional(),
  }),
});

// plus a dedicated cron loop that scans ReportSettings every minute
```

**Good:**

```typescript
const ReportSettings = z.object({
  organizationId: z.string(),
  recipients: z.array(z.string()),
});

const ScheduledTask = z.object({
  organizationId: z.string(),
  taskType: z.enum(['reportDigest', 'trainingReminder']),
  schedule: z.object({ cron: z.string(), timezone: z.string() }),
  lastRunAt: z.date().optional(),
});
```

The next feature that needs a schedule adds a task type instead of copying fields and a cron loop. Retries, locking and monitoring are written once.

**When this does not apply:**
- A throwaway proof of concept may take shortcuts if it is labelled as one.
- Designing the general mechanism costs time. A narrow first shape is acceptable when there is no second consumer yet, as long as it leaves a path to the general one.
- Parallel mechanism during replacement versus one mechanism at all times. Coexisting paths let divergence hide bugs. Building a replacement beside a legacy subsystem is often cleaner than merging new code into it. The practice accepts two paths only as a transitional state with an explicit plan to delete the old one.

## Expand, then contract, across deploys

**Principle:** Add the new side before anything uses it, and remove the old side only after nothing does, each step in its own release.

**Why:** Backend pods, frontend bundles, migrations, sibling services and infrastructure do not go live at the same instant. Cached clients can lag the server by tens of minutes, and queues hold work written by the previous version. A change that alters a contract and its consumers together leaves a window where one side asks for something the other no longer has. Ordered releases keep every intermediate state working and keep rollback possible.

**Smells:**
- One change both removes or renames a schema field, enum value or input and updates the clients that use it.
- A migration drops a column, view or function that running pods still call.
- A new required input ships in the same release as the code that starts sending it.
- A queued payload field, queue name or task handler is renamed or deleted in one step.
- Task arguments embed an entity snapshot, or deferred work reads the acting user from ambient context.
- A translated string's wording and id change in the same change that renders it.

**Do instead:**
- Order releases: additive change first, consumers next, removal of the old shape last.
- Make new inputs optional and tighten them only after every client has moved.
- For queued work, read the old field as a fallback, consume both queue names, or keep a retired handler as a no-op until the queue drains.
- Put stable ids, the acting user id and an origin marker such as live or backfill into async payloads, and fetch current data in the handler.
- Replace stateful infrastructure and identities side by side. Move dependents, including manual ones, then remove the old resource after the rollback window.
- Ship new translated strings unused first, then switch to them once translations land.

**Bad:**

```graphql
type Quest {
  id: ID!
  deadline: DateTime
}
# same release: dueDate removed, frontend query switched to deadline
```

**Good:**

```graphql
type Quest {
  id: ID!
  dueDate: DateTime @deprecated(reason: "Use deadline")
  deadline: DateTime
}
# next release: clients query deadline
# later release: dueDate removed
```

A cached client that still selects the old field keeps working during the rollout.

**Bad:**

```typescript
type ReminderTaskArgs = { userId: string; retryCount: number };

function nextAttempt(args: ReminderTaskArgs) {
  return args.retryCount + 1;
}
```

**Good:**

```typescript
type ReminderTaskArgs = { userId: string; retryCount?: number; attempt?: number };

function nextAttempt(args: ReminderTaskArgs) {
  return (args.retryCount ?? args.attempt ?? 0) + 1;
}
```

Retries enqueued by the previous version keep their count instead of restarting from zero.

**When this does not apply:**
- If no producer has ever run in any environment, the compatibility window can be skipped, provided old-shape messages fail loudly into a dead-letter queue.
- Untranslated internal tools can edit strings in place.
- Separate releases versus bundling the client fix with the server removal. Separate ordered releases mean cached clients never query something removed. A separate PR can also leave a shipped state broken when a follow-up is already planned. The practice orders by direction of data flow. Removals that only affect values the client reads from a server-returned list may ship together, and the split is guidance rather than a hard rule.
- Ids-only payloads versus enriched trigger payloads. Ids-only keeps the queue independent of schema shape. A pipeline that is polymorphic over trigger kinds may prefer to load everything once at the start so each step does not re-fetch. Use ids-only for task arguments, and treat trigger enrichment as a conscious, documented choice.
- Destroy protection on stateless infrastructure. Some consider it overkill for a cache with no persistent data. The norm is still side-by-side replacement, because losing the instance breaks whatever depends on it.

## Backfill, then tighten, in small retryable steps

**Principle:** Introduce a stored field as optional, dual-write and backfill it, verify, then tighten, with each migration one small retryable step.

**Why:** Rolling deploys and old rows mean a new field is absent for a while. A required column or non-optional type lies about what is stored and fails on old data. A migration that copies and deletes in one go loses data when it fails halfway, and one that does several stateful things leaves orphaned artefacts that collide on rerun. Work that is safe to run again turns every interruption into "fix the cause, rerun".

**Smells:**
- A new field is required in the schema or type while existing rows lack it, or code reads it with no question about backfill.
- A data-copy migration also deletes the source field.
- One migration creates a temporary object, drops the original and recreates it.
- An applied migration file is edited, or generated SQL is hand-patched to change its behaviour.
- A backfill selects every candidate record without excluding already-migrated ones, or records progress only at the end.
- An unbounded rewrite or a column type change runs on a large, hot table in a plain migration.

**Do instead:**
- Write to both old and new locations first. Backfill without deleting the old field. Confirm completeness with a query. Tighten and drop in later changes, tracked by a ticket.
- While both exist, read the successor first and fall back to the legacy field.
- Split create-new and drop-old into separate migrations, and make drops tolerate an already-missing target.
- Select only records that still need the change, upsert on natural keys, and persist progress per item or batch.
- Pick the lightest mechanism. Skip backfills that restate a default absence already implies, and set a handful of tenant exceptions through admin tooling.
- Plan large or hot-table rewrites as operational steps with explicit locking, batching and a runtime estimate from production-sized data.

For AlloyDB, `packages/server/hoxapp/prisma/AGENTS.md` already requires migrations to be generated from the schema and every migration to carry a test. The rules here cover the ordering across migrations that the doc does not.

**Bad:**

```typescript
const Department = z.object({
  id: z.string(),
  name: z.string(),
  timezone: z.string(),
});

function reminderTimezone(department: z.infer<typeof Department>) {
  return department.timezone;
}
```

**Good:**

```typescript
const Department = z.object({
  id: z.string(),
  name: z.string(),
  timezone: z.string().optional(),
});

function reminderTimezone(department: z.infer<typeof Department>, org: { timezone: string }) {
  return department.timezone ?? org.timezone;
}
```

Departments written before the field existed still parse and behave as before until the backfill is verified.

**Bad:**

```typescript
export async function up(db: Db) {
  const cursor = db.collection('departments').find({});
  for await (const department of cursor) {
    await db.collection('departments').updateOne(
      { _id: department._id },
      { $set: { timezone: await lookupTimezone(department) } }
    );
  }
}
```

**Good:**

```typescript
export async function up(db: Db) {
  const cursor = db.collection('departments').find({ timezone: { $exists: false } });
  for await (const department of cursor) {
    await db.collection('departments').updateOne(
      { _id: department._id, timezone: { $exists: false } },
      { $set: { timezone: await lookupTimezone(department) } }
    );
  }
}
```

A rerun after a crash continues where it stopped and never overwrites a value a live writer has already set.

**When this does not apply:**
- Nullability is permanent when the domain genuinely allows absence. Then no tightening step follows.
- Every multi-step sequence can still fail between steps and leave an extra object. Weigh the cost of a temporary index on a hot collection.
- Backfill versus leaving absence. A required field or low-level tooling may depend on stored values. Seeding a default that absence already implies is wasted work. Backfill when required-ness or tooling reads the stored value, and otherwise leave absence.
- Cleanup migration versus manual edit. A removal should clean stored data. For a few documents a versioned migration is heavier than an admin edit, and values that never reached users need nothing. Scale the mechanism with data size and whether values shipped.
- Transaction versus idempotent rerun. Steps that must agree belong in one transaction. Idempotent steps that skip completed work make a rerun the recovery without one. Use transactions for live entity creation where partial state would be visible, and idempotent reruns for migrations and operator-driven jobs.

## Name for the concept, not the first consumer

**Principle:** Name persisted, shared and public things after the concept they represent, not after the first consumer, vendor, mechanism or version.

**Why:** Names on collections, tables, buckets, schema types and shared helpers are expensive to change and outlive the situation that inspired them. When a second consumer, data source or implementation arrives, a consumer-specific name becomes a lie. It either forces a rename migration or misleads every reader. Naming by mechanism also couples layers, so code that only cares where something lives ends up talking about how it was produced.

**Smells:**
- A collection, table, bucket or config key named after the feature or screen that first needed it.
- A generalised helper or type that still carries the first client's or a vendor's name.
- A public GraphQL type or field whose name embeds one view, a computation detail or a default rule.
- Resource names that bind to a library, technology or internal codename.
- Version suffixes such as `V2` baked into long-lived names.

**Do instead:**
- Ask what the thing is for anyone who might use it next, and name it for that responsibility.
- Order hierarchical names from general purpose to specific consumer.
- Name by the concept the current layer cares about, and keep origin names only where the origin is the stored fact.
- When generalising, rename types and identifiers in the same change so no reference to the first use remains.

**Bad:**

```graphql
type SlackDigestRecipient {
  id: ID!
  userId: ID!
  slackChannelId: String!
}

type Query {
  slackDigestRecipients(organizationId: ID!): [SlackDigestRecipient!]!
}
```

**Good:**

```graphql
type NotificationRecipient {
  id: ID!
  userId: ID!
  channel: NotificationChannel!
  address: String!
}

type Query {
  notificationRecipients(organizationId: ID!): [NotificationRecipient!]!
}
```

Adding email or Teams delivery fits the existing type and stored collection without a rename migration.

**When this does not apply:**
- Do not generalise a name for consumers nobody expects. A name that is too abstract hides what the thing does.
- A source-specific store should name its source when a second feed is plausible, because the source is then the stored fact that distinguishes it.

## Configure only what varies; validate at startup

**Principle:** Make a value configurable only when it varies per deployment, and validate required config once at startup before any side effect.

**Why:** Hard-coded URLs, timeouts and infrastructure names force code changes whenever infrastructure moves. The opposite mistake, copying invariants into every environment overlay or making every deployment set a value only one needs, creates drift and startup failures. Config that is checked only on first use surfaces as a misattributed runtime symptom. Silent fallbacks to localhost, another component's variable or a sentinel turn misconfiguration into degraded behaviour nobody notices.

**Smells:**
- An environment-dependent URL, timeout, topic or bucket name exported as a constant.
- The same invariant value repeated in every environment overlay.
- A new required variable that crashes deployments that do not use the feature.
- A numeric value flowing into a timer or limit with no range check, or a uniqueness check placed after listeners start.
- A fallback to a localhost URL, a dev secret, another component's variable or an `UNSPECIFIED` value.
- Consumers wrapping config values in throw-if-undefined because the config type allows `undefined`.

**Do instead:**
- Keep per-deployment facts in environment config and true invariants once in code.
- Parse environment config through a schema at startup, type the result as defined, and fail with a message that names the setting.
- Give optional tuning knobs a default equal to the previous behaviour.
- Default to the safe production behaviour and make disabling a dependency an explicit flag.
- Make identity-forming or unique-per-instance parameters required. State in the API what an unspecified field means.
- Parse a value strictly where it is used when only one component needs it, so a typo fails that component and not every service.

**Bad:**

```typescript
export const config = {
  exportServiceUrl: process.env.EXPORT_SERVICE_URL ?? 'http://localhost:4100',
  exportTimeoutMs: Number(process.env.EXPORT_TIMEOUT_MS),
  virusScanUrl: process.env.VIRUS_SCAN_URL,
};
// a missing scan URL quietly skips scanning
```

**Good:**

```typescript
const EnvSchema = z.object({
  EXPORT_SERVICE_URL: z.string().url(),
  EXPORT_TIMEOUT_MS: z.coerce.number().int().positive().default(30_000),
  VIRUS_SCAN_DISABLED: z.enum(['true', 'false']).default('false'),
  VIRUS_SCAN_URL: z.string().url().optional(),
}).refine(env => env.VIRUS_SCAN_DISABLED === 'true' || env.VIRUS_SCAN_URL, {
  message: 'VIRUS_SCAN_URL is required unless VIRUS_SCAN_DISABLED=true',
});

export const config = EnvSchema.parse(process.env);
```

A missing URL crashes at boot with the setting's name, and turning scanning off takes explicit intent.

**When this does not apply:**
- Values that are semantically code, such as asset paths or invariants, stay in code even if someone wants to restrict who reads them.
- Local-only tools may keep convenient defaults.
- A legitimate configuration that disables every flow should boot with a warning, not refuse to start.
- Moving validation earlier may need a shared shape to change. A narrow, alerted race window is sometimes accepted instead.
- Hard-coded value versus configuration. Varying values belong in config. Invariants belong in code once, and new settings should default rather than become mandatory everywhere. Make a value configurable if and only if it varies per deployment, with defaults that preserve previous behaviour.
- Where defaults live. Tuning knobs benefit from code defaults with env overrides so they can be turned in an incident. Environment-specific values such as URLs must not have code fallbacks that can reach production. Keep code defaults for tuning knobs, and move environment values to validated config with no fallback.
- Opt-in enable flag versus default-on with explicit disable. Off by default keeps a new environment quiet. An enable flag that every production workload must remember will be forgotten. The practice settled on production behaviour as the default and an explicit disable flag for the exception.

## Launch dark behind an explicit signal

**Principle:** Ship new behaviour off by default, gated at one boundary by a flag named for the behaviour, never inferred from an unrelated setting.

**Why:** A switch makes rollback a configuration change instead of a deploy. It also stops unfinished features from leaking or writing data before their consumer exists. Gating at one boundary gives one place to switch and one place to delete, while flags threaded through queries and registries multiply the places that must agree. Inferring behaviour from an environment name or an incidental property couples it to settings that change for other reasons, and the resulting bug is silent and far from its cause.

**Smells:**
- A new route, scheduled job or resolver for an unfinished feature is active as soon as it merges.
- A core query gains an exclusion clause for an unreleased type, or registry entries carry a flag field.
- A flag check sits inside a component while the route is always registered.
- A branch on the environment name, a hostname prefix, or the presence of an unrelated setting decides a safety step.
- Behaviour inferred from incidental facts: children being present, a name suffix, an optional parameter happening to be set, or source order.
- A new validation guarded by a skip flag, so no data about its failures is collected.

**Do instead:**
- Default the switch off, offer a manual trigger for testing, and flip it when ready. Gate per organization for external surfaces.
- Put the gate around the whole route or operation, or at the handler that writes new data. Keep core data paths unaware of it.
- Run new checks in observe-only mode, log their verdicts, and enforce once the data supports it.
- Introduce a purpose-named flag or discriminator that defaults to the safe value, set where deployment decisions are made.
- When expressing the intent needs another layer's internals, add the missing abstraction to that layer.

**Bad:**

```typescript
async function scanExtensions(ctx: Ctx, input: ScanInput) {
  if (process.env.APP_ENV === 'development') {
    return runScan(input, { skipSignatureCheck: true });
  }
  if (ctx.organization.integrations.length > 0) {
    return runScan(input, { includeRiskScore: true });
  }
  return runScan(input, {});
}
```

**Good:**

```typescript
async function scanExtensions(ctx: Ctx, input: ScanInput) {
  return runScan(input, {
    skipSignatureCheck: config.SIGNATURE_CHECK_DISABLED,
    includeRiskScore: hasFeature(ctx.organization, 'extensionRiskScore'),
  });
}
```

Each behaviour has its own named switch with a safe default. Renaming an environment or adding an integration can no longer flip it.

**When this does not apply:**
- Explicit declarations add some boilerplate. Whether a separate declaration is worth it when a convenience parameter works is a judgement call.
- Flag by default versus no paranoid flags. A flag makes rollback a config flip. When behaviour is already gated by tenant configuration, or the change is small and contained, a flag adds management cost without reducing risk. Flag unless one of those holds.
- Where a temporary branch between implementations lives. Inside the owning handler, callers stay unaware of variants. At the call site, in-progress code iterates without disturbing production code. This is unresolved, so decide deliberately and remove the branch when the rollout ends.
- Separate flag versus deriving from an authoritative setting. A purpose-named flag avoids proxies. For security-relevant modes, an independent flag can be misconfigured out of step with the setting it should follow. Derive when the existing setting has the same meaning, and add a flag when it merely correlates.
- Cutover order. Disabling the legacy path first avoids duplicate effects but leaves a gap with neither path active. The practice disables first, makes the activation idempotent and rerunnable, and guards the gap with a flag.

## Replacements converge, removals complete

**Principle:** Ship every replacement with a path to one version, finish every removal down to stored data, and never repurpose a published identifier.

**Why:** A v2 added beside v1 without deprecation leaves two versions indefinitely, and callers cannot tell which to use. A transitional field in a public schema gains consumers and can never leave. Deleting a concept from code alone leaves stale values in documents, obsolete indexes and nullable leftovers in the API, and runtime branches that repair legacy shapes forever. Identifiers are persisted by systems you do not see, so reusing or rewording one makes old references point at the wrong thing.

**Smells:**
- A new component or type is added beside the old one with removal deferred to "later", and nothing marks the old one deprecated.
- A field named `newSomething` appears beside the old one in a public schema.
- A deprecation marker that points to no replacement.
- A flag, enum value or field removal deletes the code but leaves values in stored documents, indexes in databases or the field in the API.
- Saved user configuration such as filters still refers to the removed concept.
- A registry entry is deleted so its code can be reissued, or a message's meaning changes while its id stays.

**Do instead:**
- Replace outright where possible. Otherwise mark the old deprecated in the same change, pointing to the new, and track removal as a ticket.
- Keep the existing public field and let its resolver pick the source during the migration.
- Name lingering escape hatches so they look wrong, and scope compatibility exemptions narrowly and temporarily.
- Pair code removal with a cleanup migration and a search of stored configuration. Cascade deletes from the owner to everything it owns.
- Soft-delete identifiers with a reason, and give changed meaning a new versioned id.

**Bad:**

```graphql
type User {
  id: ID!
  riskScore: Float
  # will replace riskScore
  newRiskScore: Float
}
```

**Good:**

```graphql
type User {
  id: ID!
  # resolver reads the new model when present, else the legacy value
  riskScore: Float
}
```

Clients never see a transitional name, so finishing the migration needs no schema change on their side.

**Bad:**

```typescript
const OrganizationSettings = z.object({
  locale: z.string(),
  // legacyTheme removed from the schema; nothing else changed
});
```

**Good:**

```typescript
const OrganizationSettings = z.object({
  locale: z.string(),
});

export async function up(db: Db) {
  await db.collection('organizationSettings').updateMany(
    { legacyTheme: { $exists: true } },
    { $unset: { legacyTheme: '' } }
  );
}
```

The removal reaches stored data too, so no later reader has to tolerate a value the code no longer knows about.

**When this does not apply:**
- A re-export hop from an old module to a new registry is fine as a deliberate, short-lived transition.
- Deprecating before an alternative exists is worse than not marking it at all.
- Values that never reached real users need no data migration. For a handful of documents an admin edit may be cheaper.
- Records that serve as an audit trail, or user choices tied to a temporarily inactive upstream entity, should be retained or hidden rather than deleted.
- Identifiers that are provably internal and never persisted can be renamed freely.
