---
name: simmer
description: Work autonomously toward a stated condition — dispatch a worker, evaluate progress with a cheap model, and loop until the condition is met or the iteration cap is reached.
---

# simmer — condition-driven autonomous loop

When the user invokes `/simmer <condition>`, enter a dispatch-evaluate
loop that continues until the condition is satisfied or the iteration
cap is reached. The framework handles waking you between turns — never
poll.

## Setup

1. Extract the **condition** — everything after `/simmer`.
2. Set **max_iterations** to 20 (unless the user specifies a cap).
3. Set **iteration** to 0, **stall_count** to 0, **last_gaps** to empty.
4. Acknowledge the goal to the user in one sentence, then begin the
   loop immediately in the SAME turn — do not end a turn having only
   announced intent.

## Briefing the worker

The worker sub-agent starts with a blank slate — it has none of
your conversation history with the user. Your first dispatch must
compensate for this. Before dispatching, assemble a **briefing**
that includes:

- **The condition**, stated precisely.
- **Conversation context**: summarise what the user discussed before
  invoking `/simmer` — goals, constraints, decisions made, files or
  modules mentioned, preferences expressed. Read back through the
  conversation and extract anything the worker would need. Do not
  just forward the condition string — a worker that doesn't know
  WHY the user wants something will make poor decisions.
- **Repository context**: the working directory, relevant paths,
  the repo/project name, the branch, and any other orientation
  the worker would need to start productively.
- **What "done" looks like**: translate the condition into concrete,
  verifiable criteria when possible. "All tests pass" becomes "run
  `mix test` and get zero failures." "Refactor the auth module"
  becomes "extract X into Y, update callers, tests green."

Keep the briefing concise but complete — a few paragraphs, not a
transcript. Think of it as the handoff you'd write for a colleague
picking up your ticket.

## Loop

### Step 1 — Dispatch worker

Send the task to an implementer sub-agent:

```
sys_session_send(
  agent: <pick the appropriate worker>,
  title: "simmer-worker",
  args: {
    purpose: "implement",
    input: <briefing on first iteration, focused update on subsequent>
  }
)
```

- **First iteration**: send the full briefing assembled above.
- **Subsequent iterations**: send the evaluator's specific feedback
  and a short summary of what was already attempted. Do NOT re-send
  the entire briefing — the worker's conversation is preserved via
  title reuse, so it remembers prior iterations.

End your turn after dispatching. The framework wakes you when the
worker finishes.

### Step 2 — Collect worker output

Call `sys_read_inbox` to get the worker's result. Summarise the
outcome in 2-3 sentences (for your own context, not for the user).

### Step 3 — Verify before evaluating

If the condition is mechanically verifiable (tests pass, lint clean,
file exists, endpoint returns 200), **verify it yourself** before
dispatching the evaluator. Run the relevant command via
`sys_os_shell` and check the output. Don't take the worker's word
for it — workers sometimes claim success prematurely.

If verification passes, skip the evaluator and go straight to
reporting success (Step 4, condition met). If it fails, include the
actual failure output in the evaluator dispatch so the evaluator
has ground truth, not just the worker's self-assessment.

If the condition is subjective or can't be mechanically verified
(e.g., "write a good joke", "improve readability"), proceed to the
evaluator.

### Step 4 — Dispatch evaluator

Send the worker's summary to an independent evaluator.

Pick a DIFFERENT agent from the worker for cross-vendor independence
(e.g., worker=claude_code → evaluator=codex, and vice versa).

```
sys_session_send(
  agent: <different agent from worker>,
  title: "simmer-eval",
  args: {
    purpose: "review",
    input: "Evaluate whether the following condition is met.

CONDITION: <condition>

EVIDENCE:
<worker output summary, plus any verification output from Step 3>

Answer these four questions clearly and concisely:
1. Is the condition met? (yes or no)
2. How confident are you? (high / medium / low)
3. What gaps remain? (list them, or say 'none')
4. What should the next step focus on? (one sentence, or 'n/a')"
  }
)
```

Include raw evidence (test output, command results, diffs) when
available — not just the worker's narrative. The evaluator should
judge from evidence, not from the worker's self-report.

End your turn. The framework wakes you when the evaluator finishes.

### Step 5 — Read verdict and branch

Call `sys_read_inbox` and read the evaluator's response. The inbox
returns text blocks — use your own understanding to extract the
verdict, do not rely on strict parsing.

- **Condition met with high confidence** →
  Report success to the user. Summarise what was accomplished and how
  many iterations it took. STOP.

- **iteration >= max_iterations** →
  Report timeout. Summarise progress made and remaining gaps. STOP.

- **Same gaps as last iteration** →
  Increment stall_count. If stall_count >= 3, escalate to the user:
  "Simmering stalled after {iteration} iterations — the same gaps
  persist: {gaps}. Want me to continue with a different approach, or
  take over?" STOP and wait for input.

- **Otherwise** →
  Reset stall_count to 0. Update last_gaps. Increment iteration.
  Go to Step 1.

## Stall recovery

If stall_count reaches 2 (one short of escalation), try changing
tactics before the final attempt:

- **Switch worker agent**: if claude_code stalled, try codex (or
  vice versa). Close the old worker session first
  (`sys_session_close`) so the new one starts fresh.
- **Decompose the condition**: break a complex condition into smaller
  sub-goals and address the stuck part directly.
- **Provide more guidance**: instead of repeating the same dispatch,
  add specific hints from the evaluator's feedback and your own
  understanding of the problem.

## Model selection

The evaluator's job is lightweight — it just judges a condition. To
save cost, pass a cheap `model` on the FIRST evaluator dispatch
(model override only applies at session creation; subsequent sends
to the same title reuse the existing session and its model).

The model must match the evaluator agent's harness family:
- **Claude agents** (claude_code): use `claude-haiku-4-5`
- **Codex/GPT agents** (codex): use `gpt-5.4-mini`
- **Multi-model agents** (pi, openai-agents): either works

If unsure, call `sys_list_models` to see what each worker supports.
Shorthand like `"haiku"` is not accepted — always use full model IDs.
If the model override is rejected, retry without it — the evaluator
running on a default model is better than not running at all.

## Rules

- **Dispatch in the same turn you decide to act.** Never end a turn
  after only announcing intent — that stalls the loop because no
  inbox wake arrives.
- **Never poll.** No `sys_timer_set` loops, no `sys_read_inbox`
  spinning. Dispatch, end your turn, let the framework wake you.
- **Reuse session titles.** `"simmer-worker"` and `"simmer-eval"`
  preserve conversation context across iterations. Only
  `sys_session_close` them if you need a clean slate (e.g., switching
  worker agent on stall recovery).
- **Evaluator independence.** The evaluator should judge the
  condition from evidence, not from your assessment. Pass raw output
  (test results, diffs, command output) when available.
- **Worker boot failure.** If `sys_session_send` returns an error
  (missing CLI, agent not found), report it immediately — do not
  retry silently.
- **Keep your context lean.** Your job is dispatching and judging,
  not doing the work. Summarise aggressively between iterations.
- **Prefer evidence over narrative.** When something is checkable,
  check it. A passing test suite is worth more than a worker saying
  "I think it works."
