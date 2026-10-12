# Data model design

These guidelines cover how facts are shaped, named, identified and stored: documents, tables, GraphQL types, Zod schemas and analytics events. The shared stance is that a model should state the truth once, in the place that owns it, in a shape the type system and the database can enforce. Every reader should get the guarantees from the model itself instead of re-deriving them. When consumers need workarounds, treat that as a defect in the model, not in the consumer.

## Events are flat, raw and generic

**Principle:** Emit events as flat, typed scalar fields holding raw facts and ids, named after the generic action, and extend the existing event at the same grain before adding a new one.

**Why:** Analytics stores query columns, not serialized objects. A stringified domain object breaks silently when the upstream model changes, and an app-computed verdict freezes an analysis decision that analysts may want to make differently. An event name that hard-codes its first variant forces a new event or a rename for every later variant, and analyses cannot group across them. Narrow parallel events repeat the same ids and force joins to rebuild one funnel that a single wide row would have answered.

**Smells:**
- A property whose value is a JSON string of a nested object.
- A boolean verdict such as `isLate` or `passed` where the raw seconds, score or amount is available.
- Display names, email lists or other unbounded arrays in event or log attributes.
- An event name that embeds a vendor, format or entity type while the same detail also appears as a property.
- A new event fired from a code path that already emits an event with the same ids, or separate `enabled` and `disabled` events from one toggle.
- A base event schema gaining an optional field that only one producer can fill, or a payload field that reuses an envelope name such as `id`, `source` or `time`.

**Do instead:**
- Ask what question the event answers, then flatten it into ids, a bounded status enum, counts and raw measurements. Let the warehouse define buckets and thresholds.
- Name the event after the action and carry the subject as a typed field: one `reportExported` with a `format`, not one event per format.
- Append nullable columns to the existing event at the same grain, and use one `changed` event with a state field when both directions fire from the same place.
- Keep the envelope for fields valid on every event. Put framework metadata under its own namespace, and give each concept such as "when it happened" one documented attribute.
- Before a new stream goes live, decide how a consumer built later gets history. Prefer replaying stored data through the same pipeline over a separate one-off transform.

**Bad → good:**

**Bad:**
```typescript
analytics.track('reminder_sent', {
  organizationName: org.name,
  quest: JSON.stringify(quest),
  recipients: users.map(u => u.email),
  isOverdue: daysSinceAssigned > 14,
});
```

**Good:**
```typescript
analytics.track('reminder_sent', {
  organizationId: org.id,
  questId: quest.id,
  recipientCount: users.length,
  daysSinceAssigned,
});
```

The good event can be filtered and grouped column by column, carries no personal data, and lets analysts pick their own "overdue" threshold without a code change.

**Bad:**
```typescript
analytics.track('csv_report_exported', { organizationId, reportId });
analytics.track('pdf_report_exported', { organizationId, reportId });
analytics.track('xlsx_report_exported', { organizationId, reportId });
```

**Good:**
```typescript
type ReportFormat = 'csv' | 'pdf' | 'xlsx';

analytics.track('report_exported', {
  organizationId,
  reportId,
  format,
});
```

A new format needs no new event, and "exports per week" is one query instead of a union of three.

**When this does not apply:**
- Minimal does not mean thin. Outcome details people will ask about belong on the event, as long as they describe the event's grain. Heavy per-item detail belongs in logs or the domain store.
- Over-generic names hide meaning. Keep the name scoped to what the event actually means; do not stretch it and then narrow it in the description.
- Fine-grained events per transition versus one event with a state field: separate events make each purpose obvious, while one event is simpler to analyse. When both directions fire from the same code path, prefer one event with a state field.
- Rich outcome detail versus minimal events: adding per-step outcome lists answers likely questions, but approximating entity state through ad-hoc attributes is lossy. This is unsettled. Add compact outcome detail such as failed step names and a skip reason, and verify internals with tests or logs rather than events.

## Make invalid states unrepresentable

**Principle:** Shape types so that only legal combinations type-check: one variant per mode, optional only when truly absent, invariants enforced where the value is created.

**Why:** A flat type with a status and several nullable fields makes every reader work out which combinations are legal, and it allows "success with an error message". A discriminated union puts that knowledge in the compiler, which removes non-null assertions, defensive checks and runtime refinements. Optionality that lies costs someone either way: false optional spreads pointless fallbacks, and false required lets code dereference data that old records or error paths do not have. Validating once at construction means every downstream layer can trust the value instead of re-checking it.

**Smells:**
- A success flag next to an optional error or reason that can disagree with it.
- An enum value like `custom` paired with an optional companion field and a runtime "both or neither" refinement.
- A field made optional on a shared model so one new query, a partial update or an unsaved object type-checks.
- Absence encoded as `''` or the string `'null'`, or an all-nullable result type next to an `errors` array.
- A model holding both a singular legacy field and its list successor, read with "this or else the first of that".
- The same type used for raw parsed input and for validated, persisted data.

**Do instead:**
- Split into one type per variant keyed by a literal discriminator, and switch on it.
- Make a field required with a schema default and a backfill when it should always exist; mark it optional only when it can genuinely be unknown.
- Use separate types for separate states: unsaved versus persisted, joined versus un-joined query output.
- Collapse parallel special-case fields into one uniform shape and migrate the old field away.
- Parse input into an input type and build the domain type only through a validating constructor. Accept only the validated type in the persistence layer.

**Bad → good:**

**Bad:**
```typescript
type ConnectionCheck = {
  ok: boolean;
  latencyMs?: number;
  errorCode?: string;
  errorMessage?: string;
};

function render(check: ConnectionCheck) {
  return check.ok
    ? `Healthy (${check.latencyMs!} ms)`
    : `${check.errorCode!}: ${check.errorMessage ?? ''}`;
}
```

**Good:**
```typescript
type ConnectionCheck =
  | { ok: true; latencyMs: number }
  | { ok: false; errorCode: string; errorMessage: string };

function render(check: ConnectionCheck) {
  return check.ok
    ? `Healthy (${check.latencyMs} ms)`
    : `${check.errorCode}: ${check.errorMessage}`;
}
```

A healthy check with an error code can no longer be built, and the renderer needs no assertions.

**Bad:**
```typescript
type NotificationSchedule = { cadence: 'daily' | 'weekly'; weekday?: Weekday };

async function saveSchedule(input: NotificationSchedule) {
  await store.save(input);
}
```

**Good:**
```typescript
type NotificationSchedule =
  | { cadence: 'daily' }
  | { cadence: 'weekly'; weekday: Weekday };

async function saveSchedule(input: NotificationSchedule) {
  await store.save(input);
}
```

A weekly schedule without a weekday is rejected at compile time instead of being discovered when the scheduler runs.

**When this does not apply:**
- Only write a union when variants carry different fields. Variants with identical fields add ceremony and narrow nothing.
- Legacy schema tooling that cannot separate input and output types may force optional fields for partial updates. Accept that consciously and keep it at the edge.
- Tightening a widely shared type can touch many files. Deferring it to a tracked follow-up is acceptable; so is deferring a collapse of parallel fields when the migration is costly.
- Type precision versus type-level complexity: encoding every constraint can produce omit-and-intersect gymnastics that cost more than they protect. Use unions when variants differ, keep types simple otherwise, and accept a guarded cast only where runtime correctness is guaranteed.
- Validating outputs as well as inputs: some prefer validate-on-create for responses too, others trust values the function itself built. Factory functions for outputs are enough in practice; full output validation is optional.
- Shared envelope versus flattened variants: common fields can live in an envelope with variant data nested under a discriminated result, or each variant can extend a shared base. Both are acceptable as long as each variant's fields are required where they exist.
- Invariant on the resource versus on the input: a check on the resource covers every input path, while input validation gives earlier feedback. Put the invariant on the resource, and keep input validation too where early feedback matters.

## Closed sets: typed, and named by meaning

**Principle:** Type every value from a known set as that set, name each value by what it means to the consumer, and make lifecycle transitions explicit.

**Why:** A bare `string` accepts typos, stale values and renames without complaint. Typing the field with the set and keying lookup tables by it turns every addition into a build error in each place that must handle it. An enum value that bakes in a cause, vendor or parameter grows a new member for every new case and turns each into a schema change. A state guard widened to admit one more case lets every transition through.

**Smells:**
- A field, prop, argument or GraphQL field typed `string`/`String` while an enum for the same concept exists, or a description that lists the allowed values.
- `Record<string, X>` whose keys are a finite known set, or string literals that happen to match enum members.
- A `switch` over a union with a quiet `default`, or a state recognised by a missing field.
- An enum value named after one cause or source, or with a parameter baked in, such as `LAST_30_DAYS`.
- An update selector loosened from one allowed from-state to no condition.

**Do instead:**
- Use the existing enum or literal union everywhere, and reference its members instead of retyping them. In the Percolator domain this is already a stated rule in `packages/server/hoxapp/imports/server/domains/percolator/CLAUDE.md`; it applies equally elsewhere.
- Declare lookup tables `as const satisfies Record<Union, X>`, and add a `never` check when dispatching over a union.
- Expose closed sets as GraphQL enums sourced from the server's enum, so clients can enumerate them.
- Use a generic state plus a separate reason or source field; split parameterised options into value and unit.
- List the allowed from-states in every transition, and store only states the system can actually observe.

**Bad → good:**

**Bad:**
```typescript
const difficultyIcon: Record<string, IconName> = {
  beginner: 'seedling',
  intermediate: 'sprout',
  advanced: 'tree',
};

const icon = difficultyIcon[quest.difficulty] ?? 'seedling';
```

**Good:**
```typescript
const difficultyIcon = {
  beginner: 'seedling',
  intermediate: 'sprout',
  advanced: 'tree',
} as const satisfies Record<QuestDifficulty, IconName>;

const icon = difficultyIcon[quest.difficulty];
```

Adding an `expert` difficulty fails the build until it has an icon, so the silent fallback is no longer needed.

**Bad:**
```graphql
enum AccountStatus {
  ACTIVE
  DISABLED_BY_ADMIN
  DISABLED_BY_DIRECTORY_SYNC
  DISABLED_FOR_INACTIVITY
}

type Account {
  status: AccountStatus!
}
```

**Good:**
```graphql
enum AccountStatus {
  ACTIVE
  DISABLED
}

type Account {
  status: AccountStatus!
  disabledReason: AccountDisabledReason
}
```

Consumers that only care whether the account works check one value, and a new disable cause extends the reason set without touching the status.

**When this does not apply:**
- Open-ended or externally extensible value sets stay strings. When a raw upstream value space is much larger than what is supported, keep a string at the raw layer and narrow it with a mapper.
- The type may stay wider when the dependency direction forbids importing the narrow type.
- Enum versus literal union: enums force imports everywhere, while the compiler checks literal unions just as well. Either is fine if the set is closed and typed. Newer code favours schema enums or literal unions, and when a schema enum exists its accessor is used rather than a retyped literal.
- Strict enum versus plain string column: keep the application enum enforced at input even when the database column stores text. Prefer text columns with application enums over database enums.
- More variants versus fewer: split values exactly where some consumer acts differently, so a partial result never reads as a pass, and collapse variants every caller treats the same.
- Keeping an explicit entitlement for a capability everyone has can still pay off for rollout and tiering.

## One concept, one name, one entity

**Principle:** Give each concept one name and one representation across every layer, and add a new entity only for a genuinely new concept.

**Why:** When a term means one thing in the backend and another in the frontend, or one field carries two meanings, readers conflate them and code paths start mixing values. Two fields that both state a fact can disagree, and every reader must pick one. Each translation between parallel models is a place where meaning drifts and casts collect. The opposite failure, storing a concept in an entity built for another because the shape fits, corrupts the meaning of both.

**Smells:**
- One field or parameter whose meaning depends on the caller.
- A frontend term for something the backend already names, or two entities whose names differ only by plurality.
- Inputs that can contradict each other, such as a flag next to the value it gates, or a start, end and duration all stored.
- A resolver mapping API enum values to domain values through a lookup table, or filter arguments converted through intermediate types.
- A new collection with the same schema as an existing one and no stated reason, or a feature's state stored as records of an unrelated entity with a magic tag.

**Do instead:**
- Adopt the domain and backend vocabulary everywhere, and rename mismatches before they spread. Use `kind` or `type` for discriminators, not `name` or an id-flavoured field.
- Encode each fact once. Derive dependent values, or validate the combination and fail loudly.
- Make API enum values equal to domain values and delete the mapping. Extend the existing union or filter shape instead of inventing a parallel one.
- Before adding an entity, state the use case and look for one that already models it. When two entities share a shape on purpose, write down why they are separate.

**Bad → good:**

**Bad:**
```typescript
const TrainingWindowInput = z.object({
  startsAt: z.date(),
  endsAt: z.date(),
  durationDays: z.number().int().positive(),
});
```

**Good:**
```typescript
const TrainingWindowInput = z.object({
  startsAt: z.date(),
  endsAt: z.date(),
});

const durationDays = (w: TrainingWindow) =>
  differenceInCalendarDays(w.endsAt, w.startsAt);
```

There is no way to send a window whose duration disagrees with its dates, so no reader has to decide which field wins.

**Bad:**
```typescript
const apiToDomainRisk = { HIGH_RISK: 'high', LOW_RISK: 'low' } as const;

const resolvers = {
  Query: {
    departments: (_, { risk }) =>
      findDepartments({ risk: apiToDomainRisk[risk] }),
  },
};
```

**Good:**
```typescript
// GraphQL enum generated from the domain RiskLevel: HIGH, LOW

const resolvers = {
  Query: {
    departments: (_, { risk }) => findDepartments({ risk }),
  },
};
```

One vocabulary from schema to database means a new level needs no mapping edit and cannot be mistranslated.

**When this does not apply:**
- A translation at an external boundary is unavoidable. Keep it in one place and use type guards there.
- A stored discriminator can be kept deliberately for querying, provided invalid combinations are validated.
- Reusing a pipeline or entity versus giving a new concept its own path: plugging into shared infrastructure inherits middleware and keeps things unified, but disguising a different concept as an existing one is a hack. Reuse when the concept is the same; masquerading is acceptable only as an explicit throwaway proof of concept.
- Reusing an existing type versus adding a precise one: reuse avoids parallel types, but a type that claims every value carries a field it does not is a lie. Reuse when the existing type is truthful for all values; otherwise add the new type or derive it from a generic.
- Per-source input schemas versus one generic input: per-source schemas keep knowledge of what each source provides, while one generic shape keeps the core simple. Prefer the generic shape with normalisation at the ingestion border.

## One canonical identity per entity

**Principle:** Give each entity one stable id, use it everywhere, reference by it rather than by attributes, and derive composite ids deterministically from every distinguishing dimension.

**Why:** When an entity has two ids, every caller must know which to use and lookups multiply. Names change, collide and can be sensitive, so keys built from them break on rename and can leak customer data. A lookup on a non-unique attribute silently picks the first match. Random or positional ids make the same data look like a different entity on every read, which defeats caches, list reconciliation and dedupe.

**Smells:**
- A document with both a surrogate id and a natural unique id, plus an extra index to translate between them.
- An API input that asks for two ids of the same entity, with comments explaining which is which.
- A comparison, cache key or translation key built from a display name.
- A find on a non-unique attribute that takes the first result, or a mutation that targets an entity through a related entity's id.
- A `randomUUID()` per render or per query to satisfy a list key or a cache.
- A composite key joined with a bare separator, or one that includes mutable attributes.

**Do instead:**
- Make the natural unique id the primary id when one exists, and resolve foreign-system ids once at the boundary.
- Name each id field after the identity space it holds, and use one generic id plus a type discriminator for polymorphic links.
- Let the store mint ids and return them from writes; keep identifying fields out of patch bodies, and always carry the tenant id.
- Build composite ids from the minimal set of fields that make a row unique, with explicit field markers.
- Decide explicitly what happens when a non-unique lookup matches more than one entity.

**Bad → good:**

**Bad:**
```tsx
function IntegrationList({ items, current }: Props) {
  return items.map(integration => (
    <IntegrationCard
      key={integration.displayName}
      integration={integration}
      selected={integration.displayName === current.displayName}
    />
  ));
}
```

**Good:**
```tsx
function IntegrationList({ items, current }: Props) {
  return items.map(integration => (
    <IntegrationCard
      key={integration.id}
      integration={integration}
      selected={integration.id === current.id}
    />
  ));
}
```

Renaming an integration, or having two with the same label, no longer changes which card is selected.

**Bad:**
```typescript
const rows = aggregates.map(a => ({
  id: `${a.policyId}-${randomUUID()}`,
  policyId: a.policyId,
  day: a.day,
  blockedCount: a.blockedCount,
}));
```

**Good:**
```typescript
const rows = aggregates.map(a => ({
  id: `org:${a.organizationId}|policy:${a.policyId}|day:${a.day}`,
  policyId: a.policyId,
  day: a.day,
  blockedCount: a.blockedCount,
}));
```

The same row gets the same id on every query, so a client cache merges it and two organisations or days can never collide.

**When this does not apply:**
- Cross-system replication can force a store-local surrogate next to the canonical id. The canonical one is what crosses boundaries.
- Truly ephemeral rows with no identity and no reordering can be keyed by position.
- A deterministic key must be revisited when a new distinguishing dimension appears.
- Derived versus semantic index names: semantic names tell readers what an index is for, while names derived from the index spec cannot clash and need no versioning. Prefer derived names, and record the intent elsewhere.

## Data lives with its owner

**Principle:** Name one system of record for each fact, route writes through it, and store state on the entity whose scope and lifecycle it shares.

**Why:** A second writer, a hand-pasted copy or manually created state diverges from its source without notice. Comparing values from stores with different freshness gives wrong answers. State put in the wrong home leaks: per-user data on an organisation entity surfaces in admin views, and runtime bookkeeping on a configuration entity ends up in generated schemas. Shared documents written by many clients let one client tamper with everyone's data.

**Smells:**
- A sync job writing into a table that an official pipeline also feeds.
- Mutation inputs for fields an external provisioning system owns.
- A decision made by comparing a live count with a nightly-synced copy.
- Allowlists or reference data pasted into config from another owner.
- Per-user state stored on a shared or organisation-wide document, or in browser storage so it repeats per device.
- A storage key with the owner id at the leaf instead of the root, or embedded rows repeating their parent's id.

**Do instead:**
- Write through the agreed path, or scope a new writer to data nobody else writes.
- Expose only operations the system of record cannot do itself, and ask the owning API for answers.
- Generate or sync external reference data from its owner.
- Put per-user state on the user, runtime state in its own record apart from configuration, and give each writer documents it alone owns.
- Root storage keys at the owning entity, such as `orgs/<id>/...`, so everything an owner has can be found and deleted together.

**Bad → good:**

**Bad:**
```typescript
type Organization = {
  _id: string;
  name: string;
  announcementBanner: { id: string; text: string };
  bannerDismissedByUserIds: string[];
};
```

**Good:**
```typescript
type Organization = {
  _id: string;
  name: string;
  announcementBanner: { id: string; text: string };
};

type User = {
  _id: string;
  dismissedBannerIds: string[];
};
```

A user's dismissal is written to their own record, so the organisation document stops growing with headcount and no user writes to a shared document.

**Bad:**
```typescript
const exportKey = (orgId: string, month: string) =>
  `exports/${month}/${orgId}.csv`;
```

**Good:**
```typescript
const exportKey = (orgId: string, month: string) =>
  `orgs/${orgId}/exports/${month}.csv`;
```

Listing or deleting everything an organisation owns becomes one prefix operation.

**When this does not apply:**
- Temporary manual access during setup is acceptable when it is time-boxed and has a removal ticket.
- Deleting dependants versus retaining records: removing an owner should cascade to what it owns, but stored user choices should not vanish because an upstream entity is briefly inactive, and issued credentials deserve a permanent record. Delete what is truly owned and dead; keep data that encodes user intent or audit history and model its state instead.
- Entity snapshot versus querying sources at evaluation time: recording bounded facts on the owning entity keeps reads to one entity, while fetching from the source ships faster and avoids denormalised data and backfills. A direct fetch is acceptable when the need is near-term; the snapshot is the shape to move toward once the facts are queried from more than one place.

## Store the decision, derive the function

**Principle:** Persist decisions and facts explicitly, set by one writer, and never persist or accept writes for a value that is a fixed function of other data.

**Why:** When a decision is re-derived from proxies, every reader must know the inference rule, and the rule drifts between them. An explicit field set once can be indexed, queried and enforced by the database. The opposite also hurts: a stored derived value drifts from its inputs, and a writable aggregate lets callers create states the underlying facts do not support. Defaults applied by read-then-patch code at each use site duplicate the rule and miss new records.

**Smells:**
- Several readers re-deriving the same state from timestamps, counters or array positions, each with their own window or threshold.
- One flag implicitly coercing another value, so later code must rediscover the coupling.
- A computed, API-only field declared on the persisted schema, or an input that lets callers set aggregates.
- A boolean hide column that every consumer must remember to filter on.
- A migration that backfills a new field while the schema has no default, or a handler that patches a default in on read.
- Input types that let callers set ids, timestamps or other fields the store owns.

**Do instead:**
- Store the decision at write time: an outcome, an expiry, a chosen branch. Once it exists, read it first and fall back to derivation only for legacy data.
- Keep derived values on the API type only and compute them in the resolver, an accessor or a view.
- Change aggregates through the underlying facts plus a recalculation.
- Pair every backfill with a schema default, enforce timestamps in the database, and remove store-owned fields from input types.
- Avoid creating rows that must be hidden; if you must, hide them at the database layer.

**Bad → good:**

**Bad:**
```typescript
type QuestAttempt = { userId: string; questId: string; score: number };

const passed = (a: QuestAttempt) => a.score >= 70;

const certificateDue = attempts.filter(passed);
const dashboardPassRate = attempts.filter(a => a.score >= 75).length;
```

**Good:**
```typescript
type QuestAttempt = {
  userId: string;
  questId: string;
  score: number;
  outcome: 'passed' | 'failed';
};

const certificateDue = attempts.filter(a => a.outcome === 'passed');
const dashboardPassRate = attempts.filter(a => a.outcome === 'passed').length;
```

The grader decides once, readers cannot disagree on the threshold, and changing the threshold later does not rewrite history.

**Bad:**
```typescript
const ContactSchema = z.object({
  firstName: z.string(),
  lastName: z.string(),
  fullName: z.string(),
});
```

**Good:**
```typescript
const ContactSchema = z.object({
  firstName: z.string(),
  lastName: z.string(),
});

const fullName = (c: Contact) => `${c.firstName} ${c.lastName}`;
```

A rename can no longer leave a stale full name behind, because there is nothing to keep in sync.

**When this does not apply:**
- Store a derived value when you filter, index or audit by it, or when computing it is expensive. Then one writer must own it.
- Explicit stored discriminators allow invalid combinations, so validate them.
- When the derivation source is ambiguous, an explicit mapping file can be the source of truth.
- Store versus derive: store the value when it encodes a decision or when you query by it, and derive it when it is a pure function of fields already held.
- Schema default plus migration versus an idempotent setter: defaults set once are cleaner, but an idempotent set-if-absent mutation is narrower, and some write paths bypass schema defaults. Both are acceptable depending on the write path. Reads never patch.

## Model from the questions consumers ask

**Principle:** Start a model from the questions its consumers must answer, keep only facts that change an action, and treat consumer workarounds as gaps in the model.

**Why:** Mirroring every distinction of an upstream system multiplies states, parsers and noise without changing any decision. Fields maintained by hand drift as soon as they are written, and a list of owners leaves nobody accountable. When consumers need a direct store write, a hardcoded constant or a stack of helper views to use the data, the model cannot express the need, and every future reader pays for the workaround.

**Smells:**
- A type growing one field or state per variant the source system distinguishes.
- Output formats and parsers gaining a branch for each upstream variant.
- A hand-maintained field whose truth drifts, or a list of owners where one is accountable.
- A rule evaluation that pulls ever-growing lists from other collections to decide an entity-level outcome.
- A handler writing straight to the store because the generic update cannot express the change, or a UI hardcoding a category the backend does not model.
- A view whose only job is to join other views for a generator.

**Do instead:**
- Write down the questions the model answers, and map every source state onto those answers.
- Treat extra source detail as presentation, or fetch it from the source when needed.
- Model one accountable owner, and add derived lists only when they can be collected automatically.
- Record bounded facts, such as counts, on the owning entity when events happen, so evaluation is one read.
- Add the missing attribute to the model. If a workaround must ship first, encapsulate it and ticket the model change.

**Bad → good:**

**Bad:**
```typescript
type ManagedDevice = {
  id: string;
  mdmState:
    | 'enrolled' | 'pendingEnrollment' | 'enrollmentFailed'
    | 'retired' | 'wiped' | 'lost' | 'quarantined' | 'compliant'
    | 'nonCompliant' | 'inGracePeriod' | 'unknown';
};

const needsProtection = (d: ManagedDevice) =>
  !['retired', 'wiped', 'lost'].includes(d.mdmState);
```

**Good:**
```typescript
type ManagedDevice = {
  id: string;
  coverage: 'protectable' | 'outOfScope' | 'unknown';
  mdmStateRaw: string;
};

const needsProtection = (d: ManagedDevice) =>
  d.coverage === 'protectable';
```

The mapping from upstream states lives in one ingestion function, consumers ask the one question they care about, and new upstream states do not ripple through every reader.

**When this does not apply:**
- Some prefer keeping the real names of upstream things in the model for clarity. Keep the raw value available, as above, but do not branch on it outside the mapping.
- Recording facts on the entity means denormalised data that needs backfills. A direct fetch is acceptable when there is a near-term need.
- Views can be a pragmatic way to express polymorphic relations that schema config cannot.
- Full contract up front versus minimal first version: a complete shape with placeholder fields lets work run in parallel, while a minimal first version avoids guessing. This is unsettled; whichever you choose, the shape must allow additive change without breaking clients.
- Business logic in SQL views versus application code: views feeding a generated API avoid hand-written API code, but algorithms buried in migrations are hard to find, test and iterate. Keep business algorithms in application code, and use views as a transformation layer.

## Shape storage by its queries

**Principle:** Promote anything queried, joined or referenced to columns and foreign keys, choose collection shapes by their dominant operation, and tie every index to a concrete read path.

**Why:** Identifiers buried in a JSON blob cannot be indexed, constrained or joined, and end up queried with path operators or text matching. Deriving a first-class entity from a child table means it does not exist until a child appears, and the query gets slow. Shapes chosen by habit make operations awkward: dynamic dotted paths for removal, linear searches for lookup, positional unpacking. A query that misses its index becomes a full scan that grows with the collection, while speculative indexes cost on every write.

**Smells:**
- A reference to another entity, or a dedupe key, inside a JSON field that other queries filter on.
- A cohesive multi-field setting split into several independent nullable columns, or folded into an unrelated JSON blob.
- A map keyed by id plus a parallel ordering array, so removal needs a dynamic unset and a pull.
- An array of key/value pairs that every caller searches, or identity held only as a map key.
- A new collection without indexes for its lookup keys, or a compound index that leads with a field the query can omit.
- An unanchored regex or a cast-to-text `LIKE` over a JSON column.

**Do instead:**
- Promote queried values to columns and relations to foreign keys, with a migration of existing data. For AlloyDB, follow the schema workflow in `packages/server/hoxapp/prisma/AGENTS.md`.
- Store a cohesive config as one optional JSON column validated by a schema on read, with a recorded size budget.
- Use a list of id-bearing objects when items are removed by id, and a keyed record when access is by key. Keep identity inside each item.
- Add indexes in the same change as the queries that need them, leading with always-present fields. Guard index-dependent queries with an explain-based test.

**Bad → good:**

**Bad:**
```sql
CREATE TABLE notification_delivery (
  id uuid PRIMARY KEY,
  organization_id uuid NOT NULL,
  sent_at timestamptz NOT NULL,
  details jsonb NOT NULL
);

SELECT * FROM notification_delivery
WHERE details->>'templateId' = $1;
```

**Good:**
```sql
CREATE TABLE notification_delivery (
  id uuid PRIMARY KEY,
  organization_id uuid NOT NULL,
  sent_at timestamptz NOT NULL,
  template_id uuid NOT NULL REFERENCES notification_template(id),
  details jsonb NOT NULL
);

SELECT * FROM notification_delivery WHERE template_id = $1;
```

The template reference can be indexed, constrained and joined, and deleting a template cannot leave dangling deliveries.

**Bad:**
```typescript
type Playlist = {
  _id: string;
  questsById: Record<string, { title: string; addedAt: Date }>;
  order: string[];
};
// remove: $unset `questsById.${id}` and $pull { order: id }
```

**Good:**
```typescript
type Playlist = {
  _id: string;
  quests: { questId: string; title: string; addedAt: Date }[];
};
// remove: $pull { quests: { questId: id } }
```

Order and identity live in one array, so removal is one operation and the two structures can never disagree.

**When this does not apply:**
- Small JSON objects are fine while nothing indexes into them. Once a field is queried, promote it.
- Background writers tolerate more indexes than user-facing write paths.
- Columns versus a JSON object for co-required sub-values: one validated object keeps members together and is reusable, while separate columns with a check constraint keep data queryable. Put queried or relational values in columns; cohesive config may be JSON.
- List versus keyed record: lists make removal a pull and keep identity in the item, records make lookup by key simple. The dominant operation decides.
- Indexes up front versus only for existing lookups: index every key an existing query uses, justify each index by a concrete read path, and weigh the write cost on hot collections.
- Replacing an index in place via a temporary copy versus treating indexes as immutable: a temporary index keeps queries served, but it is costly on hot collections and a multi-step migration leaves orphans on failure. Create the new index and drop the old one in separate retryable migrations, with an exists-check on the drop and non-semantic names.
