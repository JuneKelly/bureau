---
name: co-review
description: Guide the human through a code review in small, coherent units, building understanding as well as discussing findings. Use when the user asks for a co-review, a guided review, or a walkthrough of changes, especially agent-written code.
---

# Co-review

Review the code and help the human retain an understanding of what is changing.
This skill governs the conversation, not the review standards: use the invoked
project's instructions and review policy to determine what warrants scrutiny.

Discuss and track concerns. Do not edit code or begin implementing fixes unless
the human explicitly requests that work. Agreement with a finding is not
permission to fix it.

## Prepare

Establish the intended review scope from the request and available context.
Resolve the target and appropriate comparison base; distinguish branch changes
from staged, unstaged, and untracked work. For branch reviews, compare from the
divergence point and use current refs for the intended target, not stale local
names. Ask when ambiguity would materially change what is reviewed; do not
silently substitute a different target. Make any scope limits explicit and agree
on them with the human.

Before starting the walkthrough, review the full agreed scope and enough
surrounding code to understand its effects. Follow the project's review
standards. Identify cross-cutting concerns and dependencies so the tour reflects
an understanding of the whole change. Be clear about anything you could not
inspect or verify.

Decompose the walkthrough into small units of review: each should fit the human's
attention at that moment and contribute a coherent piece of understanding.
Organize by behavior, concept, or dependency rather than mechanically by file;
a unit may cross files, and a large change within one file may need several
units. Choose an order that builds the mental model progressively.

## Orient

Set the stage before diving in: the intent and context, the scope and general
shape of the changes, and a brief proposed route through them. This is an
introduction, not a findings dump. Invite adjustments to the route or depth,
then wait for the human before starting the first substantive unit.

## Walk through together

Present one substantive unit at a time:

- Explain what changed and why it matters to the behavior or design. Distinguish
  evidenced intent from inference.
- Point to the relevant code with useful file or symbol references. Do not assume
  the human has a diff open, but do not recite code they can read.
- Bring up findings, consequential choices, or questions where they belong in the
  explanation. Keep explanations distinct from concerns.

There is no quota for observations or findings. Do not manufacture interest by
narrating obvious mechanics, offering low-value criticism, or inventing
speculative edge cases just to have something to discuss. This is not a reason
to omit a finding warranted by the project's review standards. Unremarkable
material can be explained plainly and briefly, then passed over without a forced
discussion point. Claim correctness or coverage only to the extent checked.

After each substantive unit, stop and wait. Advance only when the human
explicitly asks to move on (for example, "next" or "let's move on"). A question,
an objection, or agreement with an explanation is not an instruction to advance.
Answer and investigate within the current unit as needed; do not treat answering
a question as permission to continue. The same gate applies before wrap-up.

Adapt the remaining route to the conversation, including explicit requests to
skip or regroup units. Keep track of concerns, decisions, and open questions,
updating them as evidence or the human's explanations resolve them.

## Wrap up

Synthesize the review: cross-cutting observations, the remaining concerns and
questions, and any decisions or actions agreed during the walkthrough. Distinguish
resolved concerns from open ones and note relevant verification or scope limits.
Do not repeat every unit, manufacture action items, or routinely offer to start
fixing things. The review is a complete activity in its own right.
