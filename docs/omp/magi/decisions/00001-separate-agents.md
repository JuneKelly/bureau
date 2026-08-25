# Decision 00001: Keep Council Roles as Instructions

- **Status:** Accepted
- **Date:** 2026-08-25

## Context

MAGI has three substantively distinct council perspectives:

- **MELCHIOR** evaluates technical truth.
- **BALTHASAR** evaluates system stewardship.
- **CASPER** evaluates human intent.

All three currently share the same runtime capabilities, tools, read-only safety boundary, deliberation lifecycle, output contract, and cross-examination protocol. They are dispatched as separately
named instances of the formal `magi-deliberator` agent, with each perspective supplied through its task assignment.

The decision is whether these perspectives should instead become three formal OMP agent types.

## Decision

Keep a single formal OMP agent type, `magi-deliberator`, and continue supplying the MELCHIOR, BALTHASAR, and CASPER role charters as instructions to three separately named task instances.

Formal agent types should represent distinct capability or policy boundaries. The council members currently differ in analytical obligation, not in runtime capability or safety policy.

## Rationale

- The MAGI specification requires three distinct perspectives and independent first opinions, but does not require distinct runtime agent types.
- Stable task names and role-specific assignments already preserve council identity and analytical separation.
- The common read-only policy, tools, isolation rules, and reporting contract remain centralized in `magi-deliberator`.
- Three formal agent definitions would duplicate shared policy and create opportunities for configuration drift.
- Formal type identity would not itself guarantee independent reasoning or substantive differentiation.
- No observed OMP behavior demonstrates that separate formal types would provide stronger isolation, validation, prompt binding, or telemetry.

## Consequences

### Positive

- Shared safety and capability policy has one source of truth.
- Changes to common deliberation behavior remain easier to audit and maintain.
- Runtime concepts reflect actual capability boundaries rather than persona names.
- The architecture remains minimal and reversible.

### Negative

- A missing or misassigned role charter may still invoke a valid `magi-deliberator`.
- Operational traces may be unclear if they expose only agent type and omit stable task names.
- First-round isolation remains instruction-enforced unless OMP provides stronger runtime isolation.

## Rejected alternatives

### Three formal role-agent types

Define separate `melchior`, `balthasar`, and `casper` agent types, each embedding its role charter.

Rejected because the roles currently have identical capabilities and safety policies. This would add duplicated policy surfaces without a demonstrated runtime benefit.

### Shared agent with extracted charter templates

Keep `magi-deliberator`, but move each role charter into a reusable file or template.

Not currently necessary. This remains the preferred refinement if charter discoverability, reuse, or assignment maintenance becomes a demonstrated problem.

## Constraints

- Dispatch exactly three separately attributable task instances.
- Use stable names based on MELCHIOR, BALTHASAR, and CASPER.
- Give each first-round instance the common dossier and only its own role charter.
- Do not expose peer conclusions until cross-examination.
- Keep the shared read-only policy, tools, and output contract centralized.
- Preserve visible protocol failures and dissent.

## Reconsideration triggers

Reconsider this decision if:

- a council role needs different tools, permissions, model, lifecycle, resource limits, or safety policy;
- OMP formal agent types provide materially stronger prompt binding, isolation, validation, or telemetry;
- operational traces cannot reliably attribute work using stable task names and agent IDs;
- role charters are repeatedly omitted or assigned incorrectly;
- external integrations require formal role-type identifiers; or
- OMP supports inheritance or composition that provides formal role identities without duplicating shared policy.
