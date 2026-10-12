# Code design

These guidelines are about where logic lives and how it flows. The shared stance is that every rule, shape and piece of state has exactly one owner. Data is processed once at the edge, and generic code stays ignorant of its callers. Names, types and tests should tell the truth about what the code does. Most of the smells below come from the same root: two places that must agree, with nothing forcing them to.

## One owner per rule, one path per write

**Principle:** Give every rule, check, default and encoding one owner, and route every read and write of an entity through the one guarded path.

**Why:** Two code paths that answer the same question with separate logic drift apart, and the bug then shows up in only one of them. Guarantees such as access control, telemetry and change events hold only while every write goes through the guarded layer. One raw write makes that assumption false for everyone who relies on it. A workaround at one caller leaves every other caller with the same defect and leaks the callee's internals outwards.

**Smells:**
- A new access helper next to the central feature or licence gate, or two resolvers each spelling out the same permission check.
- Save and run, or create and load, validating the same entity with different code.
- A handler reading the raw store and re-applying tenancy or "active only" filters itself.
- A side effect or change event attached to a purpose-named setter while the generic update path can change the same field silently.
- A timeout, retry or cache added at one call site to compensate for the component that owns the resource.
- Every handler wrapping its body in the same guard, or in a try/catch that only logs.

**Do instead:**
- Extract the rule into one named function in the owning module and call it from every path, tests included.
- Read through the accessor that applies the domain policy, and layer forced tenancy parameters on top of client filters so they can never widen access.
- Attach invariants, side effects and change events to the lowest write path every caller passes through.
- Fix the owner: move deadlines, internal keys and errors into the component that holds the resource.
- Put cross-cutting guards, logging and rate limiting in the dispatcher or middleware that runs every unit.

**Bad → good:**

**Bad:**
```ts
export const reportSummary = async (ctx: TCtx, { reportId }: TArgs) => {
  const report = await ctx.reports.get(reportId);
  if (report.organizationId !== ctx.organizationId) throw forbidden();
  return summarise(report);
};

export const reportExport = async (ctx: TCtx, { reportId }: TArgs) => {
  const report = await ctx.reports.get(reportId);
  if (report.organizationId !== ctx.organizationId || !isAdmin(ctx)) throw forbidden();
  return toCsv(report);
};
```

**Good:**
```ts
export const assertCanReadReport = (ctx: TCtx, report: TReport) => {
  if (report.organizationId !== ctx.organizationId || !isAdmin(ctx)) throw forbidden();
};

export const reportSummary = async (ctx: TCtx, { reportId }: TArgs) => {
  const report = await ctx.reports.get(reportId);
  assertCanReadReport(ctx, report);
  return summarise(report);
};

export const reportExport = async (ctx: TCtx, { reportId }: TArgs) => {
  const report = await ctx.reports.get(reportId);
  assertCanReadReport(ctx, report);
  return toCsv(report);
};
```

There is one place to change who may read a report, so the summary can no longer show what the export forbids.

**When this does not apply:**
- Look-alike code that changes for different reasons is not one rule. See *One unit, one concern*.
- When the dispatcher cannot narrow types because dispatch is dynamic, generated per-unit validators bridge the gap.
- Raw writes versus the guarded layer. One force says never bypass the layer and extend it instead, for example by adding the missing operation. The other says an atomic conditional update the field-level layer cannot express justifies a raw write. Practice: extend the layer by default. Accept a raw write only when atomicity truly requires it, and make the bypass explicit and documented rather than hidden behind a thin new handler.
- Removing a duplicate now versus later. One force wants the value derived from its single source so a change is one edit. The other accepts the copy for now. Practice: derive when it is cheap. Otherwise accept the copy only with a drift test or a ticketed TODO, never as a silent copy.

## Process data once at the entry

**Principle:** Parse, validate, resolve and gather once at the entry, then pass final-shape values to inner logic that trusts its inputs.

**Why:** Re-parsing and re-checking in every consumer spreads null guards and string sniffing across the code, and each copy can drift. Interleaving fetches with logic hides N+1 queries and makes the logic testable only with live I/O. Collecting inputs first lets independent fetches run in parallel and leaves pure, synchronous functions over typed values. Helpers that read global config behind the caller's back behave differently from look-alike siblings, and tests must patch globals to control them.

**Smells:**
- The same JSON parse or null-to-default conversion repeated in several hooks or components.
- Leaf components filling fallbacks for fields the internal API always sends.
- Rule or check functions that are each async because each fetches its own data.
- A helper importing global config or reading environment variables while its caller already holds a context.
- An object built in one place and then patched with spreads or if-blocks at call sites.
- A discriminator computed upstream only to be turned back into options in several downstream places.

**Do instead:**
- Shape handlers as fetch, validate, compute, map. Fetch independent data with parallel calls.
- Load per-run data into one input object and make every rule a synchronous function of it.
- Normalise optional data in the parent and type leaf props as required.
- Read config once at initialisation and pass the values into factories as arguments.
- Return data from logic and let the entry point print, log or render it.

**Bad → good:**

**Bad:**
```ts
type TRule = (ctx: TCtx, ext: TExtension) => Promise<TFinding | undefined>;

const unlistedPublisher: TRule = async (ctx, ext) => {
  const allowlist = await ctx.policies.getPublisherAllowlist(ctx.organizationId);
  return allowlist.includes(ext.publisher) ? undefined : finding('unlisted', ext);
};

const tooManyPermissions: TRule = async (ctx, ext) => {
  const settings = await ctx.organizations.getSettings(ctx.organizationId);
  return ext.permissions.length > settings.maxPermissions ? finding('permissions', ext) : undefined;
};

export const evaluate = async (ctx: TCtx, exts: TExtension[]) =>
  (await Promise.all(exts.flatMap((e) => RULES.map((r) => r(ctx, e))))).filter(isDefined);
```

**Good:**
```ts
type TRuleInput = { allowlist: string[]; maxPermissions: number };
type TRule = (input: TRuleInput, ext: TExtension) => TFinding | undefined;

const unlistedPublisher: TRule = (input, ext) =>
  input.allowlist.includes(ext.publisher) ? undefined : finding('unlisted', ext);

const tooManyPermissions: TRule = (input, ext) =>
  ext.permissions.length > input.maxPermissions ? finding('permissions', ext) : undefined;

export const evaluate = async (ctx: TCtx, exts: TExtension[]) => {
  const [allowlist, settings] = await Promise.all([
    ctx.policies.getPublisherAllowlist(ctx.organizationId),
    ctx.organizations.getSettings(ctx.organizationId),
  ]);
  const input = { allowlist, maxPermissions: settings.maxPermissions };
  return exts.flatMap((e) => RULES.map((r) => r(input, e))).filter(isDefined);
};
```

Each input is fetched once instead of once per extension per rule. The rules are pure, so a test passes a plain object.

**When this does not apply:**
- External input and data from lenient stores still need checks at the real trust boundary. Check the base shape at the border and do deep per-item checks inside the loop that already visits each item.
- When the data you need depends on intermediate results, a second fetch phase is fine. The aim is separation, not one round trip at any cost.
- A refactor towards a single builder can wait when the variants are scheduled for removal.
- Eager versus lazy config. One force reads config once at initialisation and passes it down, so inner code never fetches config. The other reads config lazily for optional clients, so a deployment without that config fails only on the paths that need it. Practice: eager, explicit passing is the default. Lazy reading is reserved for optional clients whose config may legitimately be absent.

## UI state has one owner

**Principle:** Keep server state in the query cache, navigable state in the URL and derived state derived, and let components render props and fire changes from events.

**Why:** The frontend guides already require fetching at the view level, presentational components and URL state for filters. See `packages/frontend/AGENTS.md` and `packages/frontend/docs/code-patterns.md`. The reasoning behind them is that every copy of state needs a sync mechanism, and sync mechanisms go stale, loop or need guard refs. An effect that watches state and reacts hides the cause of a change and breaks when another path changes the same value. A forced refetch or store reset after a mutation usually means cache identity or merge rules are wrong, and resets retrigger every active query.

**Smells:**
- `useState` mirroring a query result and patched by hand after a mutation.
- `refetchQueries` or a whole-store reset added after a mutation with no stated reason.
- An effect that watches local state and calls the parent's `onChange` or navigates.
- Local state initialised from a prop and re-synced from it in an effect.
- One route rendering different pages depending on a boolean in state.
- A component querying the DOM globally, assigning a global handler, or removing a whole style attribute to undo one property.

**Do instead:**
- Compute values inline from props or the query result.
- Make every operation select the cache key, and add merge rules for types without ids.
- Call the setter, `navigate` or `onChange` inside the event handler that causes the change.
- Hold client state at the narrowest scope that covers its consumers: local state, then a feature context or reducer. Never use a hand-rolled module singleton.
- Use refs for owned DOM, paired add and remove listeners, and restore exactly the value you changed.

**Bad → good:**

**Bad:**
```tsx
const DepartmentPicker = ({ departments, onChange }: TProps) => {
  const [selected, setSelected] = useState<string[]>([]);

  useEffect(() => {
    onChange(selected);
  }, [selected, onChange]);

  const toggle = (id: string) =>
    setSelected((prev) => (prev.includes(id) ? prev.filter((d) => d !== id) : [...prev, id]));

  return <CheckboxList items={departments} value={selected} onToggle={toggle} />;
};
```

**Good:**
```tsx
const DepartmentPicker = ({ departments, value, onChange }: TProps) => {
  const toggle = (id: string) =>
    onChange(value.includes(id) ? value.filter((d) => d !== id) : [...value, id]);

  return <CheckboxList items={departments} value={value} onToggle={toggle} />;
};
```

The parent owns the selection and the change fires from the click that caused it. Nothing fires on mount, and there is no second copy to keep in sync.

**When this does not apply:**
- A list insertion the cache cannot infer may still need a targeted refetch or cache update. State the reason next to it.
- Mirroring props in local state. One force derives from props or the query and avoids sync effects. The other keeps an effect for initial values, parent resets or animation continuity. Practice: derive by default, and keep the effect only when a concrete UI need is named.
- Removing effects versus external triggers. One force moves every state change into event handlers. The other notes that a change originating outside the app, such as a redirect parameter or a browser event, has no handler to hook. Practice: keep a minimal effect for external triggers and delegate to a named function with error handling.

## Names tell the truth about behaviour

**Principle:** Name each function, field and flag for what it actually does, including side effects and scope, and never let something shaped as a read write state.

**Why:** Callers take names at face value and rarely read the body. A getter is assumed safe to call repeatedly, from previews, health checks and dashboards. A hidden write then fires in contexts nobody intended and makes state changes impossible to trace. Hiding asynchrony, transactions or quota spending does not remove that complexity; it moves it to callers who were not told. Ambiguous field names force consumers to guess units and meanings.

**Smells:**
- A `get`, `check` or `is` function that writes, creates a missing entry, enrols the caller or spends a quota.
- A helper that silently opens a transaction or runs detached while its name suggests a plain call.
- A validator named for more than it verifies, or an organisation-wide name on an operation over a capped sample.
- A boolean-sounding field that holds an enum, or a duration with no unit.
- Two sibling fields with near-identical names and very different meanings.

**Do instead:**
- Split into a pure lookup and an explicit operation whose name says it writes, such as `ensure`, `award`, `assign` or `persist`.
- Return the decision and let the caller perform the effect, so previews can use the lookup safely.
- Suffix numeric fields with their unit, and split overlapping outcome flags into orthogonal facts.
- When a generic-sounding helper only works for one kind of input, narrow its name and its type to that kind.
- Separate the business question from the authorisation question.

**Bad → good:**

**Bad:**
```ts
export const getQuestProgress = async (ctx: TCtx, userId: string, questId: string) => {
  const progress = await ctx.questProgress.get({ userId, questId });
  if (progress.percent === 100 && !progress.badgeAwardedAt) {
    await ctx.badges.award(userId, progress.badgeId);
    await ctx.questProgress.patch(progress.id, { badgeAwardedAt: ctx.now() });
  }
  return progress;
};
```

**Good:**
```ts
export const getQuestProgress = (ctx: TCtx, userId: string, questId: string) =>
  ctx.questProgress.get({ userId, questId });

export const awardQuestBadgeIfComplete = async (ctx: TCtx, progress: TQuestProgress) => {
  if (progress.percent !== 100 || progress.badgeAwardedAt) return;
  await ctx.badges.award(progress.userId, progress.badgeId);
  await ctx.questProgress.patch(progress.id, { badgeAwardedAt: ctx.now() });
};
```

Dashboards and previews can read progress without awarding anything. The award happens only where a caller asks for it by name.

**Bad:**
```graphql
type RetentionSettings {
  window: Int!
  isArchived: ArchiveState
}
```

**Good:**
```graphql
type RetentionSettings {
  windowDays: Int!
  archiveState: ArchiveState
}
```

Consumers no longer guess the unit or treat an enum as a boolean.

**When this does not apply:**
- Idempotent set-if-absent behind an explicit `ensure`-style name is fine. The problem is the hidden write, not lazy creation.
- Convention versus honesty. One force names a wrapper after the existing convention it resembles, so it is easy to find and call syntax stays consistent. The other refuses to reuse an established name or contract for a different shape. Practice: follow the convention when the new thing is the same kind of object, and pick a new name when the shape genuinely differs.

## Explicit inputs, injected dependencies

**Principle:** Pass every input as a parameter, take runtime resources, the clock and randomness from the injected context, and never mutate what you were given.

**Why:** A function that reads its enclosing scope, a module singleton or the wall clock hides what it depends on and cannot be tested alone. Import-time singletons exist before the app has connected and cannot be swapped or instrumented consistently. Long-lived objects that cache a client or identity keep stale references when the owner recreates them. Mutating an argument changes the caller's data invisibly, so the function's real effect is missing from its signature.

**Smells:**
- A helper declared inside a component body that reads props or hook results from scope, or a component defined inside another component.
- A module-level client connected at import time, or a default HTTP client used while the declared dependencies are empty.
- Domain logic calling the system clock or a global random source while the context offers helpers for both.
- A caller passing another handler's database client alongside the payload, or a single-consumer value stuffed into shared context.
- A worker class storing a client or user object as a constructor field.
- A helper assigning onto its input and returning it, a `let` reassigned in each branch, or keys deleted after building.

**Do instead:**
- Hoist helpers to module scope and pass all inputs. Curry a creator when one value is fixed.
- Obtain clients from the context at use time, declared by lifecycle. Inject a getter or factory instead of the ingredients.
- Pass the reference time in, or derive it from timestamps in the data. In tests, configure the context helpers with fixed values.
- Hand each unit exactly the dependencies it declared, from the composition root.
- Return a fresh object, and let each branch of a switch or if return its own value.

**Bad → good:**

**Bad:**
```ts
export const isReminderDue = (reminder: TReminder) => {
  const ageMs = Date.now() - reminder.lastSentAt.getTime();
  return ageMs > reminder.intervalDays * DAY_MS;
};
```

**Good:**
```ts
export const isReminderDue = (reminder: TReminder, now: Date) => {
  const ageMs = now.getTime() - reminder.lastSentAt.getTime();
  return ageMs > reminder.intervalDays * DAY_MS;
};
```

A test pins time by passing a date, with no fake timers or sleeps. The handler supplies the date from the context clock.

**Bad:**
```ts
const withDefaults = (settings: TNotificationSettings) => {
  if (settings.channel === undefined) settings.channel = 'email';
  if (settings.digest === undefined) settings.digest = true;
  return settings;
};
```

**Good:**
```ts
const withDefaults = (settings: TNotificationSettings): TNotificationSettings => ({
  ...settings,
  channel: settings.channel ?? 'email',
  digest: settings.digest ?? true,
});
```

The caller's object is untouched, so a later read of the original cannot see defaults it never set.

**When this does not apply:**
- A curried creator or a context hook is fine when the value is genuinely fixed for the subtree. The target is visible inputs, not a ban on closures.
- Infrastructure at the process edge, such as log timestamps, may read the real clock.
- A component that truly owns a lifecycle may hold that state. The problem is borrowing state owned elsewhere.
- Explicit declaration versus convenience parameter. One force wants a separate explicit dependency that communicates its role. The other prefers a simpler convenience parameter. Practice: lean to explicitness when the convenience would surprise a newcomer.
- Purity versus pragmatic mutation. One force never mutates inputs or shared context. The other accepts mutation as a conscious performance trade. Practice: mutate only for a measured performance reason, and flag it as debt to revisit.

## Testability is a design signal

**Principle:** Treat hard-to-test code as a missing seam, keep test-only surface out of production, and couple tests to the observable contract.

**Why:** When a test needs a real network server or polling loops, the code under test usually fuses orchestration with a collaborator it should receive. Test-aware branches and test-only exports mean production runs a path the tests never exercise, and they widen the public API. Assertions on logs, stub call counts or whole-set equality break on unrelated change while missing the real invariant. For hoxapp, the package guide already prefers handler-level integration tests and shared mock builders; see `packages/server/hoxapp/AGENTS.md`. This guideline adds the design reasoning behind those choices.

**Smells:**
- A test starts a real server on loopback to exercise retry logic, or a lib module calls the global `fetch` directly.
- An export commented "for tests", a constructor argument only tests set, or a branch on a test-environment flag.
- A fake that keeps working after close or hands out sequential ids the real service never would.
- A test reads logger arguments by position or counts calls on a client stub.
- A negative test compares the full output against an exact array, or a constant pins the size of a registry.
- A partial object literal cast to the real type in a fixture.

**Do instead:**
- Pass transports, executors and lookups in as small function-shaped dependencies, and split argument parsing from the run.
- Make fakes fail, defer and throw the way the real dependency does, and keep production types strict.
- Assert on the effect the code exists to produce: the stored record, the response, the public endpoint.
- Filter output to the entity under test, and generate cases from registry keys rather than mirroring them.
- In integration tests, call through the real entry point with the real test store, and mock only external services.

**Bad → good:**

**Bad:**
```ts
export const sendWebhook = async (url: string, body: TPayload) => {
  for (let attempt = 1; attempt <= 3; attempt++) {
    const res = await fetch(url, { method: 'POST', body: JSON.stringify(body) });
    if (res.ok) return;
  }
  throw webhookFailed(url);
};
```

**Good:**
```ts
type TPost = (url: string, body: string) => Promise<{ ok: boolean }>;

export const createWebhookSender = (post: TPost) => async (url: string, body: TPayload) => {
  for (let attempt = 1; attempt <= 3; attempt++) {
    const res = await post(url, JSON.stringify(body));
    if (res.ok) return;
  }
  throw webhookFailed(url);
};
```

A retry test answers one function call instead of standing up a server.

**Bad:**
```ts
test('should not create tasks for inactive users', async () => {
  await scheduleTraining(ctx, { organizationId });
  expect(await listTasks(ctx, organizationId)).toEqual([
    expect.objectContaining({ userId: activeUser.id }),
  ]);
});
```

**Good:**
```ts
test('should not create tasks for inactive users', async () => {
  await scheduleTraining(ctx, { organizationId });
  const tasks = await listTasks(ctx, organizationId);
  expect(tasks.map((t) => t.userId)).not.toContain(inactiveUser.id);
});
```

The test still checks its one claim when scheduling later creates extra tasks for other reasons.

**When this does not apply:**
- The adapter's own integration tests still need the real dependency. The seam is for code that uses it.
- When a log line or metric is itself the requirement, assert on it through its public sink.
- A temporary test branch is tolerable with a marked removal plan, for example while replacing a mock library.
- Isolated fixtures versus seeding through the producer. One force builds fixtures from shared builders so tests stay independent. The other seeds through the handler that owns the defaults, so fixtures cannot drift and upstream changes trigger downstream review. Practice: seed through the producer only when it owns the defaults and the coupling is wanted; otherwise use shared builders.
- Real store versus narrow fake. Practice: integration tests use the real store; unit tests use narrow function-shaped seams.
- Strict versus growth-tolerant assertions. Full-set assertions make every addition force a test update, which costs CI round-trips. Practice: use them only where forcing that update is the intent, and default to slice assertions.
- Owning unit versus realistic entry point. Practice: test logic detail with the unit that owns it, and keep a thin entry-point test where middleware and wiring matter.

## Dispatch variants exhaustively

**Principle:** Route per-variant behaviour through an exhaustive switch or table, and keep sibling implementations on one contract with the variation in data.

**Why:** If-else chains and two-way ternaries fall through silently when a new variant appears, so the new case gets the wrong behaviour with no error. A table or exhaustive switch puts each case in one place and lets the compiler list every consumer that needs updating. When one member of a family takes a different input or returns a different shape, every caller grows a special case and the family can no longer be extended in one place.

**Smells:**
- A ternary on an enum that has, or will have, more than two members.
- An if-else chain with no throwing else, or a switch with no `never` check.
- Nested ternaries or sibling flag blocks in JSX choosing between alternatives of one element.
- A growing chain of not-equal checks.
- One implementation of a shared interface adding its own method or returning a different shape.
- A return type widened to `T | Promise<T>` to suit one caller.

**Do instead:**
- Use a `Record` keyed by the union, or a switch whose default passes the value to a `never`-typed helper.
- Give each variant its own pure function or logic-free component and choose once.
- Pick one envelope for the family, input object in and uniform result out, and adapt outliers back to it.
- When one member needs a new parameter, change the whole family deliberately in its own change.
- Keep the narrow contract and adapt at the edge. Fire async work with an explicit `void` where it should not be awaited.

**Bad → good:**

**Bad:**
```ts
type TChannel = 'email' | 'slack' | 'teams';

const deliveryLabel = (channel: TChannel) =>
  channel === 'email' ? 'Sent by email' : 'Sent in Slack';
```

**Good:**
```ts
type TChannel = 'email' | 'slack' | 'teams';

const DELIVERY_LABEL: Record<TChannel, string> = {
  email: 'Sent by email',
  slack: 'Sent in Slack',
  teams: 'Sent in Teams',
};

const deliveryLabel = (channel: TChannel) => DELIVERY_LABEL[channel];
```

Adding a channel fails typecheck until it has a label. The bad side already mislabels the third channel without any error.

**When this does not apply:**
- Exhaustive handling versus tolerant fallback. One force wants compile-time exhaustiveness so a new variant forces every consumer to update. The other notes that when another system owns the enum and deploys independently, unknown values arrive before this code ships. Practice: be exhaustive inside the codebase that owns the union, and render a fallback for unknown values at boundaries such as a frontend reading backend enums.
- Guard only the dimensions that actually vary. A guard does not need to classify every variant when most of them behave the same.

## Generic layers take specifics from callers

**Principle:** Keep shared code ignorant of its consumers, and let callers inject behaviour and specifics instead of adding a flag per special case.

**Why:** Each flag doubles the paths through shared code and leaks one caller's needs into everyone's API. Once a shared piece knows one feature's names, copy or branches, every new feature must edit it, and a change for one consumer can break another. The frontend component guide already says one-off needs belong in the app layer and prefers composition over prop explosion; see `packages/frontend/docs/components.md`. The same reasoning applies to server factories, utilities and orchestrators.

**Smells:**
- An optional boolean that switches the internal logic of a generic factory, with two instances built using opposite values.
- A generically named component that imports one feature's copy or takes an entity-specific prop.
- A generic helper that checks a feature flag or logs a domain message for one caller.
- A shared library holding one domain's types or redaction logic.
- A combined sentinel such as `'both'` that only works while there are exactly two variants.
- A shared data bag that grows a field each time one plugged-in variant needs extra data.

**Do instead:**
- Accept a function, such as a predicate, transform or render callback, and derive named variants from it.
- Pass domain content as props, children or message values from the caller.
- Hoist the variation to the caller and pass the final value in.
- Use generic names such as `entityId` and `targetType` for capabilities other entities could use.
- Let each plugged-in variant declare and fetch its own data.

**Bad → good:**

**Bad:**
```ts
export const createCsvExporter = (opts: { anonymise?: boolean }) => (rows: TRow[]) =>
  toCsv(opts.anonymise ? rows.map((r) => ({ ...r, email: hashEmail(r.email) })) : rows);

const exportReport = createCsvExporter({ anonymise: false });
const exportBenchmark = createCsvExporter({ anonymise: true });
```

**Good:**
```ts
export const createCsvExporter = (transform: (row: TRow) => TRow = identity) =>
  (rows: TRow[]) => toCsv(rows.map(transform));

const exportReport = createCsvExporter();
const exportBenchmark = createCsvExporter((r) => ({ ...r, email: hashEmail(r.email) }));
```

The exporter no longer knows what an email is. The next special case is a new transform at its caller, not another flag.

**When this does not apply:**
- When moving domain behaviour up to the caller, preserve anything other systems rely on, such as existing log messages.
- Slot props versus children. One force prefers compound components and children so callers control structure without changing the component. The other prefers constrained slot props to steer uniform usage in a design system. Practice: choose deliberately per component and state the rule. The compound-versus-flat guidance in `packages/frontend/docs/components.md` is the starting point.

## One home per concept

**Principle:** Define each concept in the module that owns it, place code with its long-term owner, and keep dependencies pointing one way.

**Why:** Role sets, type guards, constructors and limits defined at the first call site drift from the canonical ones, and the next author does not find them. Catch-all modules grow into places nobody owns. Code placed with whichever caller triggered it first must move when that caller changes. Import cycles are a symptom of wrong direction; type-only import tricks hide the symptom and leave the direction wrong.

**Smells:**
- A new file defining role sets or policy constants similar to ones in the roles module.
- A consumer defining its own type guard or constructor for another module's type.
- Domain code added to a catch-all root resolver or a common folder of ambiguously named items.
- New helpers added to a domain that is scheduled for removal.
- Inline SQL in a handler, or one shared database file accumulating every entity's schema.
- A central hand-maintained list mirroring what the definitions already declare.
- A cycle "fixed" with a type-only import or by moving code into an unrelated package.

**Do instead:**
- Ask which module would make this code obsolete if it were removed, and put it there.
- Add guards and constructors to the owning module so every consumer shares one definition.
- Give each entity one home for its schema and query builders, and let handlers choose how to execute.
- Derive registrations from definitions, and key config by the module that uses it.
- Break a cycle by moving the shared piece into the lower-level module or its own leaf module.
- Keep copy, links and stacking layers in central registries instead of literals in components.

**Bad → good:**

**Bad:**
```ts
// quests/handlers/assignQuest.ts
import { canAssign } from '../lib/canAssign';
export const MAX_ACTIVE_QUESTS = 5;
export const assignQuest = async (ctx: TCtx, payload: TPayload) => { /* uses canAssign */ };

// quests/lib/canAssign.ts
import { MAX_ACTIVE_QUESTS } from '../handlers/assignQuest';
export const canAssign = (active: number) => active < MAX_ACTIVE_QUESTS;
```

**Good:**
```ts
// quests/lib/limits.ts
export const MAX_ACTIVE_QUESTS = 5;

// quests/handlers/assignQuest.ts
import { canAssign } from '../lib/canAssign';
export const assignQuest = async (ctx: TCtx, payload: TPayload) => { /* uses canAssign */ };

// quests/lib/canAssign.ts
import { MAX_ACTIVE_QUESTS } from './limits';
export const canAssign = (active: number) => active < MAX_ACTIVE_QUESTS;
```

Dependencies now point from handlers to lib only. Other modules can import the limit without pulling in a handler.

**When this does not apply:**
- Do not split a hub module merely to avoid an import when it is the concept's legitimate home.
- Integration code location. One force puts third-party ingestion in a neutral integrations area so other consumers can use the data later. The other keeps a domain's code inside its own package. Practice: no settled rule. When unsure, start in the nearest existing namespace and record the plan to extract.
- Generated config. One force generates per domain so material is colocated. The other needs one aggregated file for hands-off wiring. Practice: colocate per domain and keep one generated aggregation entry point.
- Extract versus copy when breaking coupling. One force moves the shared helper into its own leaf module. The other copies a few small pieces rather than relocating code to the wrong home or making two components know each other. Practice: extract when a natural shared home exists. Otherwise copy the small pieces and keep the copies equal with a test.

## Reuse before you build

**Principle:** Search the shared utils, the domain lib and the platform before writing, follow the sanctioned pattern and fix its gaps, and earn every new dependency.

**Why:** A local helper beside a shared one drifts, and fixes land in only one of them. Hand-rolled mechanics such as retries, loading flags or sanitisers carry edge cases the shared version already handles. An escape hatch around a framework primitive leaves the primitive's gap for the next author and adds a pattern readers must learn. Each new library brings foreign idioms and upkeep. The hoxapp guide warns that mirroring a sibling also copies its warts; see `packages/server/hoxapp/AGENTS.md`. The frontend guide names the sanctioned URL-state primitive; see `packages/frontend/docs/code-patterns.md`.

**Smells:**
- A local helper or hook that duplicates one in the shared utils package.
- A hand-written retry loop, or a local loading flag toggled around a mutation whose hook already exposes loading state.
- A custom parser, escaper or SQL string assembly beside a capable dependency already in the repo.
- A new state-management library added for one view or one dialog.
- A new mutation or store method whose naming or argument shape differs from its analogous siblings.
- A fake object or metadata override built so a framework helper accepts your input.

**Do instead:**
- Search shared utils, the domain lib and sibling apps before adding a helper. If it is missing, add it to the shared location.
- Check the library's built-in feature first, and pin its behaviour with a test before deleting custom code.
- Copy the shape of the nearest analogous API. If that convention is wrong, change it everywhere in a dedicated change.
- When the primitive lacks a capability, add it there in its own change rather than working around it at the call site.

**Bad → good:**

**Bad:**
```tsx
const ArchiveButton = ({ campaignId }: TProps) => {
  const [archive] = useArchiveCampaignMutation();
  const [isArchiving, setIsArchiving] = useState(false);

  const onClick = async () => {
    setIsArchiving(true);
    try {
      await archive({ variables: { campaignId } });
    } finally {
      setIsArchiving(false);
    }
  };

  return <Button onClick={onClick} isLoading={isArchiving}>Archive</Button>;
};
```

**Good:**
```tsx
const ArchiveButton = ({ campaignId }: TProps) => {
  const [archive, { loading }] = useArchiveCampaignMutation();

  const onClick = () => void archive({ variables: { campaignId } });

  return <Button onClick={onClick} isLoading={loading}>Archive</Button>;
};
```

The mutation hook already owns its in-flight state, so there is no second copy that can disagree.

**When this does not apply:**
- Write your own when the built-in does not fit a real requirement. Do not add complexity for cases the system will never meet.
- Consistency never overrides honesty. Do not reuse an established name or call shape for something that means something different. See *Names tell the truth about behaviour*.
- Library versus no new dependency. One force keeps the dependency set small because every library brings foreign patterns and maintenance. The other warns that hand-rolled parsers, sanitisers and SQL assembly carry unknown edge cases. Practice: use existing primitives for convenience features such as state. Use a maintained library for hard or security-relevant problems, checking first for one already adopted. Simple, well-tested hand-written code may stay.

## One unit, one concern

**Principle:** Give each distinct concern its own unit, and merge only code that changes for the same reason.

**Why:** A unit that serves two concerns has two reasons to change, so every edit risks the other concern. Boolean parameters that switch an endpoint into different behaviour hide a second operation with its own inputs, permissions and analytics. The opposite mistake matters as much. Merging code that only looks alike couples things that evolve independently, and the shared piece fills with per-consumer checks.

**Smells:**
- A boolean parameter that switches an endpoint or function into different behaviour.
- A predicate that grows conditions unrelated to its name, or a function that answers both "whether" and "how much".
- A store gaining queries for a different concept because they read the same collection.
- One generic form or save hook full of membership checks for per-variant fields.
- A schema for one consumer derived by omitting a global list of fields.
- A shared module with exactly one caller, or a grab-bag utils file.

**Do instead:**
- Create a separate endpoint or handler for the new concern.
- Split functions and stores by concept, and keep predicates truthful to their names.
- Before merging two pieces, ask whether they would change for the same reason.
- Give each variant its own form, mutation or options type, and share only small helpers.
- Define what each consumer needs explicitly instead of deriving it by subtraction.

**Bad → good:**

**Bad:**
```graphql
type Mutation {
  updateTrainingSchedule(
    organizationId: ID!
    schedule: TrainingScheduleInput!
    pauseInstead: Boolean
  ): TrainingSchedule!
}
```

**Good:**
```graphql
type Mutation {
  updateTrainingSchedule(
    organizationId: ID!
    schedule: TrainingScheduleInput!
  ): TrainingSchedule!
  pauseTrainingSchedule(organizationId: ID!): TrainingSchedule!
}
```

Each operation gets its own input, authorisation and analytics. Pausing no longer requires a schedule argument it ignores.

**Bad:**
```tsx
const messages = defineMessages({
  remove: { id: 'app.policies.remove', defaultMessage: 'Remove policy' },
});

<Button onClick={open}>{fm(messages.remove)}</Button>
<ConfirmDialog title={fm(messages.remove)} onConfirm={remove} />
```

**Good:**
```tsx
const messages = defineMessages({
  removeButton: { id: 'app.policies.removeButton', defaultMessage: 'Remove policy' },
  removeDialogTitle: { id: 'app.policies.removeDialogTitle', defaultMessage: 'Remove policy' },
});

<Button onClick={open}>{fm(messages.removeButton)}</Button>
<ConfirmDialog title={fm(messages.removeDialogTitle)} onConfirm={remove} />
```

The button label and the dialog title can change independently, so a copy edit to one cannot silently change the other.

**When this does not apply:**
- Deduplicate versus keep copies. One force extracts identical logic so copies cannot drift and fixes land once. The other keeps look-alike code separate because centralising couples things that evolve independently. Practice: deduplicate when the copies must stay identical for the same reason, such as identical cache merge logic. Otherwise tolerate the duplication and name each copy for its purpose.
- DRY versus local readability. Shapes that must be edited together for every new variant should be driven from one config. Rarely edited config that changes for different reasons is cheaper to copy than to abstract.
- Single-use helpers. Both forces want the orchestration readable as a sequence of named steps. They differ on whether single-use steps move to a lib file or stay in the flow's module taking arguments. Practice: keep the orchestration visible either way, and avoid grab-bag helper files.

## Types derive from one source

**Principle:** Declare each shape once and derive the rest, narrow with guards instead of casts, and make result types follow the projection.

**Why:** A cast tells the compiler to stop checking, so the next schema change breaks at runtime instead of at build time. Hand-written types that mirror a generated type or a schema drift silently. A read typed as the full entity while fetching a few fields promises data that is not there. The frontend guide asks for types derived from generated fragments; see `packages/frontend/docs/code-patterns.md`. The hoxapp rules show the projection-typed read and Zod as the single validation source; see `packages/server/hoxapp/docs/dev-guides/coding-rules.md`. In hoxapp, the collection API's types enforce a field projection on every call.

**Smells:**
- `as unknown as T`, an `as` cast on a literal, `@ts-ignore` or a non-null assertion.
- A membership check followed by a cast to the narrowed type.
- A hand-written interface mirroring a generated API type.
- A runtime schema hand-written to match a TypeScript type declared elsewhere.
- A projected read typed as the full document, or a fetch helper that takes a fields argument but returns the full entity.
- A function whose only job is renaming fields between two nearly identical schemas.

**Do instead:**
- Fix the producer so it returns the precise type, for example an empty list while loading.
- Annotate or use `satisfies` instead of casting a literal.
- Write `value is T` guards that take `unknown` at I/O borders, and pass them to `filter` and `find`.
- Infer types from the schema, or import generated types, and keep the schema beside its type.
- Declare the projection as a constant and type the result as a pick over its keys. Fetch only the fields the code uses.

**Bad → good:**

**Bad:**
```ts
const SEVERITIES = ['low', 'medium', 'high'] as const;
type TSeverity = (typeof SEVERITIES)[number];

const parseSeverity = (raw: string): TSeverity => {
  if (!SEVERITIES.includes(raw as TSeverity)) throw invalidSeverity(raw);
  return raw as TSeverity;
};
```

**Good:**
```ts
const SEVERITIES = ['low', 'medium', 'high'] as const;
type TSeverity = (typeof SEVERITIES)[number];

const isSeverity = (raw: unknown): raw is TSeverity => SEVERITIES.some((s) => s === raw);

const parseSeverity = (raw: string): TSeverity => {
  if (!isSeverity(raw)) throw invalidSeverity(raw);
  return raw;
};
```

The guard is reusable and the compiler narrows for you, so no cast can outlive a change to the list.

**Bad:**
```ts
type TInviteInput = { email: string; departmentId?: string; sendAt?: Date };

const InviteInputSchema = z.object({
  email: z.string().email(),
  departmentId: z.string().optional(),
  sendAt: z.coerce.date().optional(),
});
```

**Good:**
```ts
const InviteInputSchema = z.object({
  email: z.string().email(),
  departmentId: z.string().optional(),
  sendAt: z.coerce.date().optional(),
});

type TInviteInput = z.infer<typeof InviteInputSchema>;
```

Adding a field is one edit, and the type cannot disagree with what validation accepts.

**When this does not apply:**
- A local assertion is tolerable when the resulting type still truthfully describes the data. Dynamic dispatch wrappers may need a cast when a discriminant guarantees runtime correctness.
- Keeping a guard's parameter as the base string type is defensible when it should break if that base type changes.
- Keep separate named types when two shapes change for different reasons, or when reusing one would misrepresent what every value carries.
- A thin wrapper over a generic read that returns the full type inherits that imprecision. Fixing it is not worth reworking shared infrastructure for one call site.

## Generalise at the second consumer

**Principle:** Write the direct version for the one case you have, promote it to shared code when a second consumer arrives, and pick a shape that does not block that move.

**Why:** Options, providers and layers built for unsupported cases are guesses. They cost every reader now and are usually wrong about the case that eventually arrives. The opposite failure is copying when the second consumer appears, so a fix lands in only one copy. The frontend component guide already decides placement by how many apps use a component and says one-off props belong in the app; see `packages/frontend/docs/components.md`. The same rule applies to server helpers and config.

**Smells:**
- A helper parameter or option that only its single caller ever sets, or never sets at all.
- Declared options, schema fields or columns that no code path reads.
- A thin wrapper or base type whose only user is one call site.
- A component or helper copied into a second app, sometimes with a fix applied to only one copy.
- A generic UI piece or driver-level utility living inside one app or service.
- Single-consumer constants or prop types placed in a shared types file.

**Do instead:**
- Inline the single case with a precise type, and extract when the second concrete caller appears.
- Delete unused options now and add them back with their first real consumer.
- When a second consumer arrives, move the code with its helpers and messages to the shared location and import it from both.
- Keep single-consumer constants, types and styles next to their consumer.
- Prefer shapes that extend without breaking callers, such as an object parameter over positional ones.

**Bad → good:**

**Bad:**
```ts
type TFetchOptions = {
  fields?: TDepartmentFields;
  includeArchived?: boolean;
  sortBy?: 'createdAt' | 'name';
};

export const fetchDepartments = (ctx: TCtx, orgId: string, opts: TFetchOptions = {}) =>
  ctx.departments.find(
    { organizationId: orgId, ...(opts.includeArchived ? {} : { archived: false }) },
    { fields: opts.fields ?? DEPARTMENT_FIELDS, sort: { [opts.sortBy ?? 'name']: 1 } },
  );
```

**Good:**
```ts
export const fetchActiveDepartments = (ctx: TCtx, orgId: string) =>
  ctx.departments.find(
    { organizationId: orgId, archived: false },
    { fields: DEPARTMENT_FIELDS, sort: { name: 1 } },
  );
```

Readers see exactly what the one caller gets. The next caller adds the option it actually needs, shaped by a real case.

**When this does not apply:**
- Generalise now versus wait. One force builds the general model now for a recurring cross-cutting need, because ad-hoc first versions become the pattern. The other writes the direct version, because options for unsupported cases are guesses. Practice: generalise when a second concrete case exists or the concern clearly recurs across features. Otherwise stay direct with a shape that does not block the general one. Public contracts that are expensive to change may justify shaping for the next known case.
- Shared pattern now versus bespoke first. One force folds per-feature mechanisms into the shared pattern so cross-cutting concerns apply uniformly. The other accepts a bespoke version to keep delivery moving. Practice: accept the bespoke version when the refactor is large, record the unification plan, and do the refactor once the duplication spreads.
- Shared lib versus single service. Practice: generality decides, not the current number of users. Genuinely general code may live in a shared lib with one user.
- Test helpers promoted to production. Practice: promote only for a real runtime consumer, and move it into a normal lib module rather than importing from test utilities.
- Look-alike code whose consumers will change it for different reasons should stay separate. See *One unit, one concern*.
