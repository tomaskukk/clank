# API design

An API is a promise that callers build on, so its shape should state the truth and make misuse hard. These guidelines treat every signature, schema, handler and GraphQL type as a contract. The contract says exactly what is guaranteed, who decides what, and where trust is checked. The shared stance is simple. Put each decision and each check in one owning place. Expose capabilities rather than mechanics. Grow the existing surface instead of forking it. Choose shapes that let the next variant arrive without a breaking change.

## Signatures and schemas tell the truth

**Principle:** Make every type say exactly what is guaranteed: required when always present, nullable only for real absence, and no wider than what is read.

**Why:** A hedged signature moves the guessing to every caller and every callee. Optional inputs that are always passed make the callee re-check them. Nullable outputs that are never null force defensive branches into every client. A lookup that hides "not found" or "failed" behind a zero value makes callers act on fabricated data. Nullability is cheap to add later and expensive to remove, so strict is the right starting point.

**Smells:**
- An input marked optional though every caller passes it, or a boolean typed as possibly undefined.
- A function that returns an optional callback which callers must guard before calling.
- A `.catch` that logs and returns nothing at the end of a chain typed to return a list.
- A brand-new GraphQL field declared nullable out of habit while its resolver always returns a value.
- A non-null API field backed by a stored field that older documents do not have.
- A function that takes a whole entity or the whole context but reads two fields, so callers cast partial data.

**Do instead:**
- Make an input required or fixed, never optional with a default that some callers override. Return a no-op function rather than `undefined`.
- Return `null` for absence and throw, or return a typed error, for failure. Add a discriminated result kind only when more than two outcomes have a real consumer.
- Declare API fields non-null and lists as lists of non-null items. Relax only for a named absence case. Backfill with a migration, then tighten the type.
- Express absence at one level: a nullable parent with required children, not both nullable.
- Accept a `Pick` of the used fields or a small capability such as a `getRecord` function. Use a named-argument object when there are several same-typed, optional or paired arguments.

**Bad → good:**

**Bad:**
```typescript
async function findTrainingReport(
  orgId: string,
  reportId?: string,
): Promise<TrainingReport> {
  const doc = await reports
    .findOne({ orgId, _id: reportId })
    .catch((err) => {
      logger.warn('lookup failed', err);
    });
  return doc ?? { id: '', orgId, completions: 0 };
}
```

**Good:**
```typescript
async function findTrainingReport(
  orgId: string,
  reportId: string,
): Promise<TrainingReport | null> {
  const doc = await reports.findOne({ orgId, _id: reportId });
  return doc ?? null;
}
```

The good version lets callers tell "not found" (`null`) from "failed" (a thrown error). A required id means no caller can silently query for "any report".

**Bad:**
```graphql
type DepartmentSummary {
  id: ID
  name: String
  memberCount: Int
  owners: [User]
}
```

**Good:**
```graphql
type DepartmentSummary {
  id: ID!
  name: String!
  memberCount: Int!
  owners: [User!]!
}
```

Clients drop every defensive branch. Nullability now tells the truth about storage. If a value later becomes optional, relaxing the type is a non-breaking change.

**When this does not apply:**
- A short list of distinct, required, differently typed arguments reads fine positionally. Do not wrap every two-argument function in an object.
- Relaxing non-null to nullable is legitimate as a deliberate step before removing the backing data. Tooling that shares one schema between input and output can force optionality.
- An opaque JSON scalar can be a conscious short-term step if it sits in a versioned envelope with a path to the structured shape. Otherwise declare the real fields in the schema, and flatten recursive structures into typed node and edge lists.
- *Optional by nature vs non-null by default.* One force mirrors storage: optional data is nullable. The other makes fields non-null so clients stay simple. Both hold. Nullability must match storage, and the preferred fix is to make storage required with a backfill.
- *Narrow input vs legitimate need.* Narrowing prevents coupling and misuse, but some functions really need the full context. Narrow by default. Accept the wider input when a concrete need exists, and document why.
- *Projection parameter vs return type.* A helper that accepts a field projection should derive its return type from it, or the type lies. When the underlying call already lies, a wrapper may inherit that for now. Deriving the type from the projection remains the goal.

## Subject explicit, authorization declared

**Principle:** Make the tenant and subject of an operation explicit required inputs, declare who may act in the authorization layer, and confine any elevation to one named, least-privileged step.

**Why:** A scope that each consumer must remember is a latent cross-tenant leak, because the next query that forgets it exposes data. An operation that silently binds to the logged-in identity hides an authorization decision and breaks under impersonation or elevated runners. Role checks scattered in handler bodies, or a whole call wrapped in a superuser role, are invisible to anyone reading the access policy. Since any handler can call any handler, access must sit at the data access point, not in caller discipline.

The repo already states the core rules. The subject is not the caller and roles must not be escalated by reflex: see `.claude/skills/hoxapp--create-handler/references/acl-and-errors.md`. Identity examples are in `packages/server/hoxapp/docs/dev-guides/coding-rules.md`. This section adds the reasoning for scoping and privilege design.

**Smells:**
- A new boolean on a widely read collection that every query must filter on to stay correct.
- A handler that derives the organization from optional payload attributes with fallbacks.
- A loader keyed by the caller's organization instead of the parent entity's.
- A default tenant filter merged with user-supplied filters so a caller can override it.
- A handler body that re-checks roles with `if` statements although its config declares roles.
- A role list copied from a neighbour, including user roles on a destructive or outbound-sending operation with no use case.

**Do instead:**
- Require `organizationId` or `userId` in the payload and bind it with the standard input authorizer. Take it from the parent entity, not from the caller.
- Enforce visibility centrally with row-level security, a view or a query plugin. AND-wrap mandatory constraints around user logic so it cannot bypass them.
- Name each role in a handler's list after a concrete caller that exists today. Start new or abuse-prone capabilities as internal-only and widen later on purpose.
- If elevation is unavoidable, extract the single privileged step into a small function. Run it under a distinct system principal with the least-privileged role that the blocking rule exempts.

**Bad → good:**

**Bad:**
```typescript
export const archiveQuest = defineHandler({
  roles: [Role.USER, Role.ORG_ADMIN, Role.GLOBAL_ADMIN],
  async handler(ctx, payload: { questId: string }) {
    const orgId = currentSession(ctx).organizationId;
    if (!currentSession(ctx).roles.includes(Role.ORG_ADMIN)) {
      throw forbidden(ctx, 'Only admins can archive quests');
    }
    await quests.archive(asSystem(ctx), { orgId, questId: payload.questId });
  },
});
```

**Good:**
```typescript
export const archiveQuest = defineHandler({
  roles: [Role.ORG_ADMIN],
  inputPolicies: [matchOrganization('organizationId')],
  async handler(
    ctx,
    payload: { organizationId: string; questId: string },
  ) {
    await quests.archive(ctx, payload);
  },
});
```

The access rule is now readable in one place, and the subject organization is part of the contract. No superuser call runs with whatever the inner operation can do.

**When this does not apply:**
- Redundant checks that cannot change the outcome add noise. Rely on the standard enforcement where it already applies.
- Code that runs outside the handler frame, such as authenticators, cannot rely on framework validation. Authenticators should state only what they verified and leave identity and privilege assignment to the layer that owns it.
- Over-narrow access forces ad hoc elevation elsewhere. The fix then is a correct ACL, not a broader role.
- *Scoped escalation vs ACL.* Encoding access in ACLs keeps it visible. Widening a shared, widely used read handler for every role is worse than one escalation. Prefer the ACL. Accept a narrow, least-privileged escalation in a small dedicated function when the alternative widens a shared handler.
- *Elevate the context vs fix the ACL.* Adding a user role to an internal handler makes it a user-callable mutation. Ad hoc elevation sprinkled through handlers is hard to audit. Never widen user roles for an internal step. Use a named system principal for it, and prefer a correct ACL when the caller legitimately needs the handler.
- *Org-matching input policy on admin-only handlers.* The org-admin role check already matches the organization, so an extra input policy changes nothing there. Keep the input policy when the handler is also open to global roles.

## Decision lives with the knowledge

**Principle:** Let the party that can know a thing with certainty decide it, and keep each caller's input to what only that caller knows.

**Why:** When one decision is split between two parties, both can be wrong and they drift apart. A client that carries a server-side marker, or a caller that overrides a mode the stored entity already states, creates two sources of truth. A client that re-implements eligibility or variant lists needs a matching edit for every new backend variant. Defaults applied at each call site are forgotten on the next one, especially safety defaults.

**Smells:**
- A client fetches an internal marker only to send it back to the server.
- A caller-supplied override layered on a mode the persisted entity already holds.
- Callers look up and pass an internal id that the callee could resolve from what they already gave it.
- A required override argument where the backend already knows the value, or a frontend that defaults a domain value before sending it.
- A query selects dozens of raw fields so the client can compute a yes or no, or a frontend constant list enumerates backend variants.
- Every call site passes the same constant labels, safety attributes or no-op callbacks.

**Do instead:**
- Ask which side can know the answer with certainty, and give that side the decision and all candidate data.
- Accept ids or one cohesive domain object, and load, default and complete everything else inside the callee.
- Make override arguments optional, and apply the default in the domain module that owns the rule.
- Expose the domain answer as a field or argument: an availability boolean, a status enum, a count, a filter.
- Put common-case and safety defaults inside the shared component or factory, with an optional override.

**Bad → good:**

**Bad:**
```graphql
type SimulationTemplate {
  id: ID!
  targeting: TargetingRules!
  requiredLicenses: [String!]!
  archivedAt: DateTime
}
# client: canLaunch = !t.archivedAt && licenses.every(...) && matches(t.targeting, org)
```

**Good:**
```graphql
type SimulationTemplate {
  id: ID!
  canLaunch: Boolean!
  launchBlockedReason: LaunchBlockedReason
}
```

The rule lives where the data lives. A new blocking condition needs no client change.

**Bad:**
```typescript
await sendReminder({
  userId,
  locale: user.locale ?? DEFAULT_LOCALE,
  templateId: await lookupReminderTemplateId(orgId),
});
```

**Good:**
```typescript
await sendReminder({ userId });
```

The callee resolves the locale and template from the user it already loads. No call site can pick the wrong template or forget the fallback.

**When this does not apply:**
- Presentation-only knowledge stays in the client: route tables, icons, transformations of unsaved drafts. Replicating it in the backend adds upkeep with no second consumer.
- Where a schema-derived default would run at the wrong time, such as per render, explicit initial values next to the schema are fine.
- *Caller vs callee declares intent.* A caller knows its flow, so a generic shared service should not hard-code one application's choice. A component or stored entity that already knows the answer should not take a flag for it. Resolve each case by asking which side can know it with certainty.
- *Explicit subject vs callee resolution.* The subject the operation is about is the caller's explicit choice; see "Subject explicit, authorization declared". Internal ids and projections derivable from that subject are resolved by the callee.
- *Convention defaults vs mandatory parameters.* A default derived from convention keeps the common case short. A value that forms identity, must be unique per instance, or would surprise the caller should be required.

## The safe path is the only path

**Principle:** Put every mandatory safety step inside the single entry point, confine powerful primitives to their owner, and make lifecycle misuse impossible by construction.

**Why:** When a safety step lives in a separate helper or a look-alike sibling function, correctness depends on every future caller remembering it, and forgetting is silent. Folding the step into the one API removes a whole class of mistakes for a little flexibility. Sharp tools placed on a ubiquitous surface get used everywhere, and a published workaround reads as a best practice. Mutable lifecycle toggles let objects be used after they stop.

**Smells:**
- Two exported functions with the same signature where only one performs a security-relevant step.
- An exported helper that callers are expected to apply before calling another API, such as "redact, then log".
- Several partial validators that callers must remember to combine.
- A call-site comment warning about a pitfall of a shared abstraction instead of a fix inside it.
- Raw database client or cursor access added to a context every handler receives.
- A stateful client with `start` and `stop` that only flip a flag, or an `init` with no guard against a second call.

**Do instead:**
- Make the base entry point perform the mandatory step, and name it so the name states the guarantee. Make the helper private.
- Collapse partial validators into one that covers every category, or make the variants' signatures incompatible.
- Inject a primitive only into the owning handler and return materialised results. Give a finishing capability only to the party that started the operation.
- Fix the mode at construction. Offer one `close` that drains pending work and rejects later calls.
- Keep safety guards unconditional and check the final artifact. Let untrusted or model-written text fill bounded fields while code owns identifiers, structure and destinations.

**Bad → good:**

**Bad:**
```typescript
export function redactReporterEmail(report: PhishReport): PhishReport {
  return { ...report, reporterEmail: '[redacted]' };
}

export function forwardReport(report: PhishReport, target: Integration) {
  return target.send(report);
}

export function forwardReportRedacted(report: PhishReport, target: Integration) {
  return target.send(redactReporterEmail(report));
}
```

**Good:**
```typescript
function redactReporterEmail(report: PhishReport): PhishReport {
  return { ...report, reporterEmail: '[redacted]' };
}

export function forwardRedactedReport(
  report: PhishReport,
  target: Integration,
) {
  return target.send(redactReporterEmail(report));
}
```

There is no unredacted path to pick by accident. The name states the guarantee, so a reviewer does not need to know the helper exists.

**Bad:**
```typescript
class NotificationBatcher {
  enabled = false;
  start() { this.enabled = true; }
  stop() { this.enabled = false; }
  enqueue(n: Notification) { if (this.enabled) this.queue.push(n); }
}
```

**Good:**
```typescript
class NotificationBatcher {
  private closed = false;
  constructor(private readonly opts: { flushEveryMs: number }) {}
  enqueue(n: Notification) {
    if (this.closed) throw new Error('NotificationBatcher is closed');
    this.queue.push(n);
  }
  async close() { this.closed = true; await this.flush(); }
}
```

Work in flight is drained, not dropped. Use after close fails loudly instead of silently discarding notifications.

**When this does not apply:**
- When callers really need the unsafe form for a rare case, expose it under an explicit, discouraging name, never as a peer of the safe form.
- *Share a workaround or keep it local.* Publishing a powerful workaround guides the next engineer toward the hack. Some workarounds must be shared anyway. Prefer local. If shared, export only the coarsest form with a note on when it is warranted.
- *Deprecate a risky helper or document its safe use.* A helper that trusts ambient ids is unsafe for writes and org scoping. A blanket deprecation that everyone ignores helps nobody. Keep using it only where it is safe, document that context, and take target ids explicitly wherever impersonation or multi-org callers are possible.

## Hide internals, expose capabilities

**Principle:** Expose the capability a caller needs, keep mechanics, storage shapes and library types private, and decide what leaves a boundary by allowlist.

**Why:** Once a client depends on a storage layout, a library type, an internal key or a tuning knob, that detail becomes a contract that is very hard to change. Callers that must assemble raw ingredients duplicate logic and break when it changes. Anything on a public schema or a forwarded payload is reachable by every caller. Stripping known secrets misses the next one, while building output from known-safe parts cannot leak a new field. Every export must then be kept stable.

**Smells:**
- An API response that returns the persisted document as stored, or echoes an internal composite key.
- A handler payload with cache, transaction or other internal ids the caller should not choose.
- A component that requires transport fields such as `__typename`, or a provider that exports a raw error string for callers to compare.
- A proxy that forwards the full incoming header set, or a log payload that accepts arbitrary keys.
- A helper, constant or type exported only because a test or sibling file wanted it.
- A schema description that explains why the implementation works the way it does.

**Do instead:**
- Translate at the boundary into a consumer-oriented shape, distinct from the stored shape.
- Offer a named question such as `isQuotaError(err)` or `canEditPolicy` instead of the raw structure.
- Type outbound payloads as an explicit set of allowed fields, built field by field.
- Export only what a production caller outside the module needs. Use private fields with read-only accessors for values only a validating constructor may build.
- Wrap a surprising third-party or storage shape in one small accessor so the oddity lives in one place.

**Bad → good:**

**Bad:**
```typescript
export async function getIntegrationStatus(id: string) {
  const doc = await integrations.findOne({ _id: id });
  return doc;
}
```

**Good:**
```typescript
export interface IntegrationStatus {
  id: string;
  vendor: string;
  connected: boolean;
  lastSyncAt: Date | null;
}

export async function getIntegrationStatus(id: string): Promise<IntegrationStatus> {
  const doc = await integrations.findOne({ _id: id });
  return {
    id: doc._id,
    vendor: doc.vendor,
    connected: doc.tokenExpiresAt > new Date(),
    lastSyncAt: doc.sync?.finishedAt ?? null,
  };
}
```

A new secret field on the stored document stays private by default. The storage layout can change without touching callers.

**When this does not apply:**
- Leaking internals is acceptable for helpers whose only callers are in the same module. The cost appears when the surface is shared or public.
- Documentation meant for external integrators can be deliberately public. The allowlist then names it explicitly.
- Helpers that are truly generic should be exported on purpose through the package's public index, not left in an in-between utils file.

## Extend the existing surface, don't fork it

**Principle:** Add an option to the existing primitive instead of a purpose-named sibling, and make every new knob earn its place.

**Why:** Near-copy variants make callers choose between look-alike names, and every later fix must be applied to every copy. The copies drift, so behaviour differs for no intended reason. A feature name in a mutation or handler signature usually means a general mechanism was missed, and each later feature then adds its own sibling. Every knob also multiplies the states downstream code must handle and test.

The repo has rules for the component side: before adding a prop, decide whether it is a general need or a one-off, and prefer composition over prop explosion. See `packages/frontend/docs/components.md`. The hoxapp guide warns that copying a sibling copies its warts, and describes the generic collection domain: see `packages/server/hoxapp/AGENTS.md`.

**Smells:**
- A new function named like an existing one plus a suffix, such as `ForTeams` or `WithRetry`, whose body is mostly copied.
- A mutation or handler named after one feature on a collection that already serves many.
- A query copied from an existing one with only a variable name changed.
- A bespoke argument added beside an existing generic filter system.
- An argument every call site passes identically, or a parameter still accepted after it stopped having an effect.
- A new payload field marked optional with a fallback branch, while every caller lives in the same repo.

**Do instead:**
- Pass the varying piece, such as a predicate, mapper or callback, as an argument to the existing function.
- Add an opt-in option with a sensible default. Name it after the behaviour it controls, not its first use case.
- Ask what an addition gives over composing what exists. Drop it if the answer is unclear.
- Delete parameters nobody varies and parameters that are ignored.
- In the monorepo, make a newly needed field required and fix every call site the type checker reports.

**Bad → good:**

**Bad:**
```typescript
export async function listOverdueTrainings(orgId: string) {
  const rows = await trainings.find({ orgId, dueAt: { $lt: new Date() } });
  return rows.map(toTrainingRow);
}

export async function listOverdueTrainingsForDepartment(orgId: string, departmentId: string) {
  const rows = await trainings.find({ orgId, departmentId, dueAt: { $lt: new Date() } });
  return rows.map(toTrainingRow);
}
```

**Good:**
```typescript
export async function listOverdueTrainings(
  orgId: string,
  filter: { departmentId?: string } = {},
) {
  const rows = await trainings.find({ orgId, ...filter, dueAt: { $lt: new Date() } });
  return rows.map(toTrainingRow);
}
```

There is one name and one body, so the next fix lands everywhere. The common case still needs no decision.

**When this does not apply:**
- If the extra parameter would make the primitive serve unrelated purposes, or the two cases will change for different reasons, separate functions are cleaner.
- A single-purpose idempotent bootstrap or internal endpoint can stay specific until a second case appears.
- Minimal surface can push repeated boilerplate onto callers. When the same composition recurs, a named helper may earn its place.
- Keep compatibility optionals for persisted payloads, queued messages and independently deployed clients.
- *Generic store operations vs named domain operations.* One view names nodes by entity with generic leaves such as create, upsert and count, with the caller owning the query. The other wants named domain operations so generic verbs are not used with differing semantics. This is unsettled. Follow the generic collection handler convention for entity CRUD, and give substantial business operations their own named handler.
- *Evolve in place vs add alongside.* Changing an exported function silently can break callers that rely on old semantics. Inside the monorepo the type checker finds every caller. Change in place when all callers are reachable and semantics only widen. Add a new function when behaviour changes for callers that may rely on the old one.
- *Fixing a cross-cutting pattern inside a feature change.* A codebase-wide pattern, such as how upserts match, deserves its own change. Fix the local hazard, such as failing loudly on a missing id, and defer the reshape.

## Closed set over boolean

**Principle:** Model a parameter, prop or field that selects among variants as a named closed set, and shape contracts so the next variant is an additive change.

**Why:** A boolean only says on or off. When a third meaning appears it sneaks in through `undefined`, through combinations of flags, or through flags that make some calls nonsensical. A bare `true` at a call site says nothing without reading the callee. Persisted and public booleans are the most expensive to widen, because stored filters and clients already depend on the two-state shape.

**Smells:**
- An optional boolean whose `undefined` is treated as a third state.
- Several boolean options on one function that only make sense in certain combinations.
- A bare `true` or `false` argument whose meaning is only clear from the callee's source.
- An enabled/disabled boolean on an entity whose lifecycle will likely gain states such as paused or scheduled.
- One boolean per licensed feature or per cause, or optional fields documented as "only meaningful when X is set".
- A loose top-level field added to a config type with no obvious home for its siblings.

**Do instead:**
- Replace the flag with a status or variant enum, ideally defined once at the backend.
- Expose the real underlying parameter, such as the filter set or the rendered slot, instead of a proxy boolean.
- Use a discriminated union or a `oneOf` input per variant, starting with the first variant, so each carries its own fields.
- Pair an `enabled` flag with a reason enum on the shared base type when several causes can disable something.
- Group related options under a named sub-object so the next option has an obvious home.

**Bad → good:**

**Bad:**
```graphql
type BrowserExtensionPolicy {
  id: ID!
  isActive: Boolean
  isAuditOnly: Boolean
  pausedUntil: DateTime
}
```

**Good:**
```graphql
enum PolicyMode {
  ENFORCE
  AUDIT
  PAUSED
  DISABLED
}

type BrowserExtensionPolicy {
  id: ID!
  mode: PolicyMode!
  pausedUntil: DateTime
}
```

Contradictory combinations such as inactive plus audit-only cannot be expressed. A new mode is one enum value, not another flag to combine.

**Bad:**
```typescript
type ReminderSchedule = {
  weekday: number;
  hour: number;
  dayOfMonth?: number;
};
```

**Good:**
```typescript
type ReminderSchedule =
  | { kind: 'weekly'; weekday: number; hour: number }
  | { kind: 'monthly'; dayOfMonth: number; hour: number };
```

Each variant carries only its own fields, and the type checker proves which one is present. Adding a quarterly schedule is additive.

**When this does not apply:**
- A boolean is fine when the value is derived from runtime data rather than chosen at the call site, and extra states are unlikely.
- Do not build a union before a second variant is foreseeable.
- Teams differ on shipping the full contract up front with null fields versus a minimal first version. Both agree the shape must never need a breaking change to grow.
- *Boolean vs status enum.* A closed set prevents a third state leaking through `undefined`. Migrating stored references has a real cost. Weigh how likely new states are against that cost, and default to an enum for lifecycle fields.

## Graph-shaped API

**Principle:** Hang data off the entity it belongs to, group fields that belong together into named objects, give each write its own input, and return the changed entity with its id.

**Why:** Root queries keyed by entity ids turn the graph into a flat list of procedures. They mirror storage instead of domain relationships and multiply as consumers appear. Traversal from an already-scoped parent keeps tenant scoping implicit. A mutation that returns a bare scalar leaves the normalised client cache unable to place the result, so callers chain refetches by hand. A shared create-and-patch input forces fields to be both required and optional, so one of them is wrong.

**Smells:**
- A new root query that takes a parent id to return something that belongs to that parent.
- A field on a global type that takes an organization id to compute an organization-relative value.
- A field name that joins two concepts with "And", or flat nullable fields that only make sense together.
- A new list argument such as `excludeStatuses` beside an existing filter input.
- One input type used for both create and patch.
- A mutation that returns `Boolean` or `String`, or a client selection without `id`, followed by a manual refetch.

**Do instead:**
- Add the data as a field on the owning type with a field resolver. Expose both directions of a relationship.
- Keep root queries for entry by id or for filtered collections.
- Introduce a named object type for grouped fields. Make the group optional and its members required.
- Use the existing filter syntax with inclusive operators such as `status_in`, and declare input constraints in the schema.
- Name inputs per operation, such as `CreateXInput` and `PatchXInput`. Return the changed entity, or a job id for async work, and always select `id`.

**Bad → good:**

**Bad:**
```graphql
type Query {
  departmentQuestProgress(departmentId: ID!): [QuestProgress!]!
}

type Mutation {
  renameDepartment(id: ID!, name: String!): Boolean!
}
```

**Good:**
```graphql
type Department {
  id: ID!
  name: String!
  questProgress: [QuestProgress!]!
}

type Mutation {
  renameDepartment(input: RenameDepartmentInput!): Department!
}
```

Clients reach progress by traversing from a department they already have, so scoping comes from the parent. The mutation result updates every cached query that shows the department.

**Bad:**
```graphql
type Notification {
  id: ID!
  bannerTitle: String
  bannerBody: String
  bannerLinkUrl: String
}
```

**Good:**
```graphql
type Notification {
  id: ID!
  banner: NotificationBanner
}

type NotificationBanner {
  title: String!
  body: String!
  linkUrl: String
}
```

A title without a body can no longer be expressed. Absence is decided once, at the group level.

**When this does not apply:**
- Value objects with no identity do not need ids.
- Legacy upsert APIs stay until replaced. Prefer separate create and update operations in new APIs.
- *Traversal vs direct lookup.* Traversal keeps the graph coherent. An auto-generated API layer can make nested resolution costly. A direct lookup field is defensible for lazily loaded data behind such a layer. Default to traversal and treat a direct lookup as an exception that needs a stated reason.

## Transport-agnostic core

**Principle:** Keep handlers and domain models free of transport, storage and vendor shapes, and translate at each border.

**Why:** When handlers return GraphQL types, accept raw queue messages with ack callbacks, or import a vendor SDK's internals, every transport or storage change ripples into business code. Binding to another side's types couples change cycles even when there is no logical reason. A new backend enum value then breaks a frontend build. Logic inside a resolver or route bypasses the roles, telemetry and tests that the handler layer provides.

In hoxapp, the GraphQL schema and resolvers live apart from the handler tree, and handlers are created with the generator. See `packages/server/hoxapp/AGENTS.md` for where each layer lives.

**Smells:**
- A domain module imports generated GraphQL types or enums.
- A handler payload carries a raw message with ack and nack callbacks.
- An API endpoint builds storage-engine filters, or an integration handler returns internal entities instead of the external data.
- A resolver loads several entities and runs domain computation inline.
- An exported lib function publishes to a queue or calls an external API.
- A frontend map keyed exhaustively on a backend enum, so any new value fails the build.

**Do instead:**
- Map transport enums and types explicitly at the resolver, with an exhaustive switch on the domain side.
- Parse messages in the transport adapter and let it ack based on the handler's promise.
- Translate domain filters into queries inside the storage implementation.
- Make resolvers and routes pure passthroughs to a handler in the owning domain. Turn effectful lib functions into handlers.
- Route all imports from a third-party SDK through one adapter module. Use partial maps with a default branch where another side owns the key set.

**Bad → good:**

**Bad:**
```typescript
import { GqlReportVerdict, GqlReport } from '../graphql/generated';

export async function classifyReport(
  ctx: Ctx,
  payload: { reportId: string; verdict: GqlReportVerdict },
): Promise<GqlReport> {
  const report = await reports.setVerdict(ctx, payload);
  return { ...report, __typename: 'Report' };
}
```

**Good:**
```typescript
import { ReportVerdict, Report } from './model';

export async function classifyReport(
  ctx: Ctx,
  payload: { reportId: string; verdict: ReportVerdict },
): Promise<Report> {
  return reports.setVerdict(ctx, payload);
}
// resolver: classifyReport(ctx, { reportId, verdict: toReportVerdict(args.verdict) })
```

The domain can be called from a queue, a route or a task without GraphQL. A schema rename touches one mapper, not the business logic.

**When this does not apply:**
- Within one owning domain, importing the owner's schema is preferred over re-deriving it. Duplication is for crossing boundaries, not inside them.
- Some prefer the transport layer to own publishing follow-up messages; others let handlers publish. Pick one per service and keep it consistent.
- *Domain-owned API layer vs the central GraphQL layer.* Domains owning their schema and resolvers would ease a future split. The existing central pattern is what readers expect. Follow the central pattern now, and adopt domain ownership only as a deliberate decision.

## Parse at the border

**Principle:** Parse everything that enters the process into a typed internal shape at one explicit seam, then trust the types inside.

**Why:** A type annotation on untrusted data is only a promise. When a provider, a library upgrade or a crafted request changes the shape, the error surfaces deep inside and is hard to attribute. One parse at the border gives the rest of the code a single well-formed type and removes defensive field readers. A mapper at the edge keeps vendor wording out of the domain. Interfaces that take raw strings push formatting and validation onto every caller.

The repo already makes Zod the single source of truth for validation and forbids parallel validation functions: see `packages/server/hoxapp/docs/dev-guides/coding-rules.md`. This section adds where the parse belongs and what to do with vendor shapes.

**Smells:**
- A third-party response or decoded token typed by annotation or cast, with no runtime check.
- Hand-rolled field readers, or per-item loops with piecemeal defaults, instead of one schema parse.
- Raw SQL rows cast to a row type, or a JSON column typed `unknown` while a schema for it exists.
- A double cast from generated transport argument types to the domain type.
- A helper that takes a plain string payload or SQL text that the callee must trust.
- Regex or string-repair helpers inside a rendering component.

**Do instead:**
- Define a schema, `safeParse` at the entry point, and use the inferred type downstream.
- Put structural constraints such as non-empty, ranges and formats in the schema. Keep only cross-field business rules in a small rules module.
- Write a small mapping function from transport or vendor shapes to the domain type. Test vendor wording in, our enum out.
- Accept the typed domain object and serialise inside the callee.
- Have the API return structured data. If a repair step is unavoidable, put it in the client's data layer, never in components.

**Bad → good:**

**Bad:**
```typescript
async function fetchVendorThreatFeed(url: string): Promise<ThreatIndicator[]> {
  const body = (await (await fetch(url)).json()) as {
    items: { ioc: string; severity: string }[];
  };
  return body.items.map((i) => ({
    value: i.ioc,
    severity: i.severity as Severity,
  }));
}
```

**Good:**
```typescript
const VendorFeed = z.object({
  items: z.array(z.object({ ioc: z.string().min(1), severity: z.string() })),
});

async function fetchVendorThreatFeed(url: string): Promise<ThreatIndicator[]> {
  const body = VendorFeed.parse(await (await fetch(url)).json());
  return body.items.map((i) => ({
    value: i.ioc,
    severity: toSeverity(i.severity),
  }));
}
```

A shape change fails at the border with a clear error. An unknown vendor severity goes through one mapper instead of a cast that lies.

**When this does not apply:**
- Use the validation mechanism the surrounding layer already uses. Cross-field rules the schema library cannot express may live in a separate rules module.
- *Defensive validation everywhere vs trust the internal contract.* Validating in every writer feels safe. Re-checking what our own parse already guarantees is noise. Validate where data crosses a trust boundary, such as external input, privileged paths and lenient stores, and trust internal guarantees beyond that point.
- *Client-required fields vs server enforcement.* The client is not a security boundary. Some completeness rules are enforced by the platform on the client, and bypass is only deliberate abuse. Sanitise and enforce security-relevant content on the server. Non-security completeness may rely on the client.
