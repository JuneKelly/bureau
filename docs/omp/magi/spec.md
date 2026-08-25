# MAGI System Specification

## Purpose

MAGI is a deliberative decision system for the front of the software development
lifecycle. It frames ambiguous problems, tests their premises, compares possible
solutions, and produces an evidence-backed decision before implementation begins.

MAGI is a governance mechanism, not a worker pool. It determines what ought to
be done; an execution orchestrator such as Sybil determines how to implement the
accepted decision.

## Appropriate use

MAGI is appropriate when a decision involves meaningful uncertainty or tension
between technical correctness, operational safety, and human intent. Typical
uses include:

- framing an underspecified problem;
- deciding whether a problem requires a system change;
- comparing architectural or dependency choices;
- evaluating migrations and consequential compatibility changes;
- establishing constraints, non-goals, and acceptance criteria;
- reconsidering a decision when implementation reveals contradictory evidence.

MAGI is not intended for routine code generation, mechanical migrations,
localized bug fixes with known remedies, formatting, or ordinary line-level code
review.

## Council

MAGI consists of three independent perspectives and a neutral integrator.

### MELCHIOR — technical truth

MELCHIOR asks: **What is demonstrably correct?**

It tests premises, evaluates feasibility, distinguishes evidence from inference,
and prefers the smallest solution that can satisfy the desired outcome. Its
judgment is authoritative on disputed technical claims only when supported by
evidence.

### BALTHASAR — stewardship

BALTHASAR asks: **What keeps the system healthy?**

It evaluates compatibility, failure modes, data integrity, security, operations,
maintenance, migration, and recovery. It may veto destructive or irreversible
action that lacks an adequate recovery path.

### CASPER — human intent

CASPER asks: **What serves the person asking?**

It identifies the underlying user outcome and evaluates usability, surprise,
communication, organizational effects, and likely misuse. It protects explicit
human preferences and escalates value choices that evidence cannot resolve.

### MAGI-CORE — integration

MAGI-CORE coordinates deliberation and synthesizes the result. It does not add a
fourth substantive opinion or invent a compromise. Its responsibilities are to
reconcile evidence, apply the decision rules, preserve dissent, and produce the
final decision record.

## Deliberation lifecycle

1. **Frame the decision.** Establish the desired outcome, exact decision,
   evidence, constraints, assumptions, unknowns, non-goals, and known options.
2. **Form independent opinions.** Each council member evaluates the same neutral
   problem dossier through its own perspective without seeing the others'
   conclusions.
3. **Cross-examine.** Each member addresses the strongest opposing argument,
   weak claims, missing evidence, and conditions that could change its verdict.
4. **Integrate.** MAGI-CORE weighs the evidence and arguments under the authority
   rules. It does not reduce the result to a simple vote.
5. **Conclude or escalate.** MAGI emits one terminal state and a stable decision
   dossier suitable for human acceptance and subsequent execution planning.

## Decision rules

- Evidence outranks votes, confidence scores, and urgency.
- A majority cannot overrule a demonstrated technical contradiction.
- Material dissent must remain visible in the final record.
- A non-unanimous recommendation may proceed only when the proposed action is
  local, reversible, and has an adequate verification strategy.
- Destructive, irreversible, security-sensitive, data-loss, or externally
  visible action requires unanimity or explicit human authorization.
- Missing facts and human value choices are different blockers and must be
  reported separately.
- Council failure must be visible. MAGI must not impersonate a missing
  perspective or silently weaken the deliberation protocol.

## Terminal states

Every deliberation ends in exactly one state:

- **APPROVED_FOR_EXECUTION** — one solution is sufficiently specified for
  execution planning after human acceptance.
- **HUMAN_DECISION_REQUIRED** — evidence cannot resolve a material preference,
  authority question, or high-impact tradeoff.
- **INSUFFICIENT_EVIDENCE** — a material fact is missing; the result identifies
  the evidence required and how it can be obtained.
- **NO_IMPLEMENTATION_RECOMMENDED** — the desired outcome does not require code
  or system changes.

## Decision dossier

The final record must contain:

- the terminal state and decision;
- the observed evidence and material assumptions;
- each council member's initial and final verdict;
- decisive reasoning and rejected alternatives;
- material cross-examination challenges and responses;
- preserved dissent and the conditions under which it becomes controlling;
- risks, constraints, and non-goals;
- observable acceptance criteria;
- reconsideration triggers;
- unresolved human decisions; and
- the authority status of the recommendation.

The dossier is a frozen decision contract, not an implementation plan. It must
remain understandable without access to transient council state.

## Relationship to execution

An accepted MAGI dossier becomes an input to Sybil or another execution
orchestrator. The execution system owns decomposition, implementation,
integration, and behavioral verification. It must preserve the dossier's
constraints and return the problem to MAGI when a reconsideration trigger occurs.

MAGI remains read-only throughout this process. It does not edit source code,
change configuration, mutate external systems, or authorize itself to execute a
recommendation.

## System invariants

- The three perspectives remain substantively distinct.
- First opinions are formed independently.
- Claims are traceable to evidence or marked as inference.
- Confidence never substitutes for evidence.
- Dissent and protocol failures are never hidden.
- Human authority is required where specified.
- Deliberation remains proportionate; MAGI does not manufacture disagreement for
  routine or predetermined decisions.
- No execution begins solely because MAGI produced a recommendation.
