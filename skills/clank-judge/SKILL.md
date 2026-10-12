---
name: clank:judge
description: Use when asked to judge, review or sanity-check the design of a concrete change, such as a diff, a PR, a branch, a plan or a module, for data model, API, abstraction, boundary, rollout or failure-handling problems; or before requesting review of your own change. Also use when deciding where a responsibility belongs or whether to generalise, reuse or duplicate. Do not use for formatting, naming taste, lint-able rules, PR process and hygiene (see CODE_REVIEW.md), or for debugging a single failing test.
---

# Judge

## Overview

You judge one concrete change and report the design problems that will cost something real, each with evidence from the code, the consequence, and ordered steps from the current state to a better one. The output is a short ranked list of issues, not a checklist report and not a tour of what is fine.

What "better" means here, in one breath: each fact, rule and variant list has one owner; data is parsed once at the border and trusted inside; shapes tell the truth and make invalid states impossible; the party that can know a thing decides it; generalisation is earned by a second case; and every contract survives a redeploy, a retry and the largest tenant. The references hold the full guidelines with bad → good examples.

## The bar for an issue

Report something only if all three hold:

1. **Evidence.** You can point at the file and lines (or the plan section) *and* at the other place in the codebase that makes it a problem: the second copy, the other writer, the existing mechanism, the consumer that will break, the caller that cannot know, the missing migration.
2. **Consequence.** You can state what goes wrong, for whom, and what triggers it: the next variant, the next tenant size, the redeploy with old clients, the retry, the second caller, the rename. "Could become a problem someday" is not a trigger.
3. **A step exists.** You can name the first concrete move that improves the current situation inside this change.

Drop silently, without listing them: style and naming taste with no behavioural consequence; anything a lint rule or generator enforces; a generic layer this change merely uses as its siblings do; items you would label "informational", "nit" or "not for this PR"; speculative generalisation; restating what the change does well.

## Procedure

1. **Fix the target.** A diff, PR number, branch, plan file or path. If none is given, use `git diff develop...HEAD` in the repo. Read all of it.
2. **Understand the surroundings before judging.** Judging the diff alone produces guesses. For each changed unit, read:
   - the callers and the sibling implementations of a changed function, handler or resolver;
   - the write path it goes through, and what else that path owns (events, access checks, recounts);
   - every consumer of a changed or new field (grep the field name; include tests and policy or analytics code);
   - the existing mechanism for the same concern elsewhere (search by the concept noun: classification, schedule, status, approval, sync);
   - for a new stored field: its schema default, backfill migration and the rows that predate it;
   - for a new GraphQL field or argument: the generated filter and sort arguments it creates and the old clients still deployed.
   Write down the three to six facts you found. Every issue must cite at least one of them.
3. **Hunt with the smell table below.** For each row, ask whether the smell is present in *this* change, then verify it against the facts: find the second copy, the other writer, the missing backfill. A smell without a verified second place is not an issue.
4. **Rank and cut.** Order by consequence: data corruption or cross-tenant exposure, then silent wrong behaviour, then a breaking change nobody will catch, then drift or an extra edit on every future variant, then cost at scale or caller burden. Keep at most five. Zero is a valid result; say so in one line and stop.
5. **Write the issues in the format below, then stop.** No "checks that passed", no question-by-question transcript, no summary of the change beyond two lines of context at the top.

## Issue format

```
## N. <one-line claim, stated as a fact about this change>  (<blocker|high|medium|low>)

Where: <path:line, or the type, field or mutation name>
Evidence: <the fact in this change> + <the other place that makes it a problem, with its path>
Consequence: <what breaks or costs, for whom, triggered by what>
Steps to improve:
1. In this change: <the smallest move that removes the consequence; name the function, type or field>
2. Then: <the next step, if the full shape needs more than this change; what must stay compatible until it lands>
Reference: references/<pillar>.md#<slug>
```

Severity: **blocker** corrupts data, leaks across tenants or breaks running clients; **high** produces wrong behaviour or a breaking change that nothing will catch; **medium** forces a second edit on every future variant or lets two copies drift; **low** costs at scale or burdens every caller. Nothing below low is reported.

The steps are the deliverable. Step 1 must be doable inside the change under review and must name the concrete thing to add, move, rename or delete. Say which step the author can defer and what has to stay compatible meanwhile. If the right fix is an existing mechanism, name it by its path.

## Smell table

Each row: the smell, how to verify it against the code, and where the full guideline with examples lives.

### Data model (`references/data-model.md`)

| Smell in the change | Verify by | Anchor |
|---|---|---|
| Optional fields that are "always set when status is X"; a success flag beside an optional error | Find a reader that asserts non-null or guards the combination | `#make-invalid-states-unrepresentable` |
| A `string` field with a comment listing allowed values; an enum value named after its cause | Find the enum that already exists for the concept; find a lookup keyed by string | `#closed-sets-typed-and-named-by-meaning` |
| A second type, constant, enum or collection for a fact that already has one | Grep the concept noun across packages; compare value sets | `#one-concept-one-name-one-entity` |
| Lookup or key by display name, email or a mutable attribute; two ids for one entity | Find the index or cache keyed on it; find a rename path | `#one-canonical-identity-per-entity` |
| Per-user state on a shared document; a second writer to a fact another system owns | Find the other writer or the official pipeline | `#data-lives-with-its-owner` |
| A stored field that is a pure function of other stored fields; a decision inferred from a proxy | Find the readers that re-derive it, each with their own threshold | `#store-the-decision-derive-the-function` |
| Nested objects, pre-aggregated values or feature-specific names in an analytics event | Find the existing event at the same grain; check the warehouse consumers | `#events-are-flat-raw-and-generic` |
| A JSON blob holding values that are filtered or joined; an index with no read path | Find the query that filters on it; find the index definition | `#shape-storage-by-its-queries` |
| Fields nobody reads; consumers needing a bypass or helper views to answer a basic question | Find the consumer workaround | `#model-from-the-questions-consumers-ask` |

### API (`references/api.md`)

| Smell in the change | Verify by | Anchor |
|---|---|---|
| External data typed by annotation or cast; undefined checks scattered through inner code | Find the entry point and whether a schema parse exists | `#parse-at-the-border` |
| A handler that reads request headers, generated GraphQL types or raw rows; logic in a resolver | Find the handler the resolver should delegate to | `#transport-agnostic-core` |
| A public field mirroring the storage shape; an export used only inside its module | Find the external consumers of the field or export | `#hide-internals-expose-capabilities` |
| A mandatory redaction, enrichment or validation step callers must remember | Find a caller that skips it | `#the-safe-path-is-the-only-path` |
| The client computing eligibility or variant lists; a caller passing what the callee could resolve | Find the backend data the decision needs | `#decision-lives-with-the-knowledge` |
| A second boolean beside the first; flags that cannot both be true | Count the combinations the callee handles | `#closed-set-over-boolean` |
| A purpose-named sibling of a generic operation; a knob every caller sets identically | Find the generic operation and every caller of the knob | `#extend-the-existing-surface-dont-fork-it` |
| A root query taking an id for data belonging to an entity already in the graph; a mutation returning a scalar | Find the parent type and the client selections | `#graph-shaped-api` |
| A required value typed optional; `null` for both "not found" and "failed"; a helper taking the whole context for one field | Find callers that guard or cast | `#signatures-and-schemas-tell-the-truth` |
| The tenant derived from ambient identity; roles widened so an internal step can run | Read the handler's ACL config and the resolver scope helper | `#subject-explicit-authorization-declared` |

### Code (`references/code.md`)

| Smell in the change | Verify by | Anchor |
|---|---|---|
| A `get`, `check` or `find` that writes; a name promising more or less than the body | Read the body for writes and side effects | `#names-tell-the-truth-about-behaviour` |
| The same parse, default or lookup repeated per branch; leaf helpers reading config | Find each repetition | `#process-data-once-at-the-entry` |
| The same check in two handlers; a raw write bypassing the layer that owns access, events or recounts | Find what the guarded path attaches that the bypass skips | `#one-owner-per-rule-one-path-per-write` |
| A unit doing two things a caller may want separately; code merged because it looked alike | Find the two reasons to change | `#one-unit-one-concern` |
| Options, providers or plumbing for cases that do not exist; a shared package with one user | Count the callers that set each option | `#generalise-at-the-second-consumer` |
| A hand-rolled parser, retry or hook where shared utils, the domain lib or the platform has one | Search the shared location by capability | `#reuse-before-you-build` |
| A concept's predicates and constants defined at a call site; an import cycle patched with a type-only import | Find the owning module and its existing definition | `#one-home-per-concept` |
| `if`/`else` over a kind; a `default` hiding a missing case; siblings with different signatures | List the union members and the cases handled | `#dispatch-variants-exhaustively` |
| A shared component or helper naming a feature or growing a flag per special case | Find the other consumers of the shared piece | `#generic-layers-take-specifics-from-callers` |
| Helpers closing over outer variables; module-level clients or caches; `Date.now()` in domain logic | Find the context helper that should supply it | `#explicit-inputs-injected-dependencies` |
| Query results copied into local state; effects syncing one state to another | Find the owner of the state (cache, URL, parent) | `#ui-state-has-one-owner` |
| A test-only parameter or branch in production; tests asserting on log lines or call counts | Find the production caller of the test-only surface | `#testability-is-a-design-signal` |
| A hand-written type beside a schema or projection; a cast or `any` to silence the compiler | Find the source the type should derive from | `#types-derive-from-one-source` |

### Evolvability (`references/evolvability.md`)

| Smell in the change | Verify by | Anchor |
|---|---|---|
| A collection, type or resource named after the feature, vendor or version that first needed it | Find the plausible second consumer | `#name-for-the-concept-not-the-first-consumer` |
| A second way to schedule, track changes, gate or handle overload beside the established one | Find the established mechanism and what it provides for free | `#one-mechanism-per-recurring-concern` |
| A hand-maintained list, allowlist or mapper edited for every new variant | Find the registry or schema it should derive from | `#derive-variant-sets-from-one-source` |
| A field renamed, removed or made required in the same change that stops writing it; queued work the new code cannot read | List what the previous deployment still reads or writes | `#expand-then-contract-across-deploys` |
| A new required field with no backfill; a migration doing several things or not rerunnable | Find the migration and the rows that predate the field | `#backfill-then-tighten-in-small-retryable-steps` |
| Old and new way with no deprecation pointer; a removal leaving stored data, indexes or API fields | Grep the removed name in migrations, schema and saved config | `#replacements-converge-removals-complete` |
| Behaviour inferred from an environment name or unrelated setting; a new path live for everyone on first deploy | Find the gate and what else flips with it | `#launch-dark-behind-an-explicit-signal` |
| An invariant repeated across environment overlays; a missing value found on the first request | Find where the value is read and what validates it | `#configure-only-what-varies-validate-at-startup` |

### Failure and scale (`references/failure-scale.md`)

| Smell in the change | Verify by | Anchor |
|---|---|---|
| A default substituted when an invariant breaks; a broad catch that logs and continues; a raw error reaching a client | Find the error kinds the call can raise and the client that sees them | `#fail-loud-with-typed-errors` |
| Ack before the work resolved; a dedup key missing a dimension; retry without classifying the failure | Find the redelivery path and the effects it repeats | `#at-least-once-idempotent-consumers` |
| Read, condition and write as three statements; multi-step writes that can orphan | Find the concurrent caller or the retry | `#atomic-check-then-act` |
| A timeout that only rejects the promise; request state in a long-lived object; a listener nobody removes | Find the work left running and the owner of the stop | `#every-start-has-a-stop-every-wait-a-bound` |
| An unpaged list; filtering in application code the database could do; one item's failure aborting a batch | Estimate the count at the largest tenant; find the index | `#bound-cardinality-isolate-per-item` |
| A per-row query inside a page render; micro-optimisation on a rare admin path | Find how often the path runs and what calls it | `#weigh-cost-by-call-frequency` |
| An access or existence decision leaked to the client; an admin-settable value used as a selector key or proxy target | Trace the value from the request to the privileged use | `#security-is-decided-by-the-trusted-side` |
| A new attribute name for an existing concept; high-cardinality labels; personal data in logs | Find the canonical attribute and the metric series count | `#telemetry-is-a-shared-vocabulary` |

## Judging a plan instead of a diff

Same bar, same format. Evidence comes from the shapes the plan states plus the existing code it will touch, so step 2 of the procedure still runs against the repo. Steps to improve become "before writing code" steps, and the first one names the existing mechanism, type or handler the plan should build on.

## Red flags in your own output

- A consequence sentence with "could", "might" or "someday" and no trigger: delete the issue.
- A step that only restates the principle ("put it in one place"): name the file, function or field, or delete the issue.
- An issue about a generic layer this change merely uses the way its siblings do: delete it, unless this change adds new coupling to the layer's flaw (for example a test that pins its error text, or a client branching on its message). Then report the coupling, with the local step, and name the layer fix as the follow-up.
- More than five issues: you are listing smells, not issues. Cut.
- A section of things that passed, or answers to a checklist: delete it.
- A finding you would mark "informational", "nit" or "low priority, not for this PR": delete it.
