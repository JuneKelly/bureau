---
name: cross-review
description: Verify an implementer's diff with `reviewer` (cross-vendor Codex sub-agent); the reviewer gets the diff, the acceptance contract, and its own isolated worktree for full code context. Blocking issues become fix-tasks; loop until clean.
---

# cross-review — independent verification

The implementer never signs off on its own work — a different-vendor model
does, and review is a sub-agent that returns a structured report, not a
transcript anyone needs to read through.

## Inputs

Before starting, identify these from the task context:

- **Reference** — the code state to review. One of:
  - a commit SHA (in-place mode: the commit the worker just produced)
  - a branch name (fanout mode: the derived branch, e.g.
    `sybil/<topic>/<task_id>`)
  - a PR URL (when a PR already exists)
- **Diff** — how to obtain it, derived from the reference:
  - commit SHA → `git show <sha>` or `git diff <topic>...<sha>`
  - branch → `git diff <topic>...<branch>`
  - PR → `gh pr diff <pr>`
- **Implementer identity** — the `agent` + `title` (or `session_id`) of the
  worker that built it, so fix-tasks route back to the same conversation.
- **Acceptance contract** — what the diff is supposed to achieve. On a
  single-commit review this is one statement. On a **multi-commit reference**
  (a fanout branch, or an in-place branch reviewed across several rounds), keep
  the contract **scoped per round**: hold one acceptance criterion per
  commit / logical change, and on each round hand the reviewer ONLY the criteria
  for the commits present in that round's diff. Don't re-submit a single
  undifferentiated blob covering the whole branch — it forces the reviewer to
  re-litigate already-verified commits and blurs which criterion a blocking
  issue maps back to.

## Procedure

1. **Get the diff** using whichever method fits the reference (see Inputs
   above).
2. **Create an isolated review worktree** at the reference in detached HEAD:
   `sys_os_shell("git worktree add --detach .worktrees/review-<task_slug> <reference>")`
   where `<reference>` is the commit SHA, branch name, or PR head SHA.
   Detached HEAD is required so git doesn't conflict with any existing checkout
   of the same ref. The reviewer sees the full code state at the review point
   in a completely separate working copy; it is read-only by design, and any
   accidental writes are contained here and never touch the implementer's
   branch. Record the review worktree path.
3. **Run the deterministic gates** — tests / lint / typecheck via
   `sys_os_shell`. If the orchestrator environment can't run the project's
   gates (e.g. toolchain not bootstrapped), don't loop on it — rely on the
   implementer's reported gate results and have the reviewer focus on logic. If
   gates are runnable and red, re-dispatch the implementer to drive them green
   first; don't involve the reviewer yet. Remove the review worktree before
   looping back (`git worktree remove .worktrees/review-<task_slug>`), since
   re-creating it after fixes ensures the reviewer always sees the latest
   committed state.
4. **Dispatch `reviewer`** for cross-vendor verification. `builder` and `drone`
   always implement with Claude; `reviewer` always reviews with GPT — the
   cross-vendor independence is structural, not a routing decision. Use a
   task-based title such as `review-auth-refactor`, never the raw agent name:
   `sys_session_send(agent="reviewer", title="review-<task_slug>",
   args={purpose: "review", input: "<the diff> + <the acceptance contract>.
   The full code state is at .worktrees/review-<task_slug> — read any file you
   need for context, but your review is against the diff + contract. Report
   blocking / non-blocking / suggestions. Do not edit code."})`. Give the
   reviewer the diff as text AND the review worktree path — never point it at
   the implementer's working tree. When the reference spans multiple commits,
   pass only the acceptance criteria covering the commits in this round's diff
   (see Inputs) — not the whole-branch contract. Fetch the diff, create the review worktree,
   and emit the `sys_session_send` call in the SAME turn you decide to review —
   never end a turn having only announced intent with no tool call. Once the
   reviewer dispatch is in flight, end your turn; collect the inbox-delivered
   structured report with `sys_read_inbox` when it returns. Use
   `sys_session_get_history` only to debug an empty or unclear review result.
5. The reviewer **SURFACES** issues; it does not fix them.
6. For each **blocking** issue: send the concrete fixes back to the SAME
   implementer that built the diff — reuse the original implementer's `agent` +
   `title` (or address it by `session_id`) with `purpose: "implement"`, so the
   worker keeps its context. If using the registry, record fix-tasks there.
   Remove the review worktree before looping back to step 1 — it will be
   re-created from the updated reference. On the next round, scope the contract
   to the fix commit(s) and the criteria they were meant to satisfy — don't
   re-review commits that already passed.
7. When gates are green (or trusted from the implementer) AND there are zero
   blocking issues, the work passes review. If using the registry, mark it
   ready there. The deliverable depends on the mode:
   - **In-place:** the commit(s) on the topic branch are verified. The human
     manages any PR and merge.
   - **Fanout:** the derived branch is verified. Sybil merges it back to the
     topic branch (per the fanout skill's merge-back step).
8. **Clean up** the review worktree:
   `sys_os_shell("git worktree remove .worktrees/review-<task_slug>")`.
   Do this after the review loop exits — whether via step 7 (pass) or step 9
   (escalation).
9. If the contract can't be satisfied after a few loops, stop and escalate to
   the user with specifics. Clean up the review worktree before escalating.

## Notes

- Cross-review requires `reviewer` to be AVAILABLE (per sybil's roster
  preflight — `codex` must be on PATH). If `reviewer` is unavailable, you
  CANNOT run independent cross-vendor review: don't dispatch it, say so
  explicitly, and pull in the human at the plan gate.
- The reviewer gets the diff + contract AND its own isolated review worktree
  for full code context. Never point it at the implementer's worktree or
  working tree — the cross-vendor independence is the whole point.
- `reviewer` is dispatched with `purpose: "review"`. It reports issues and
  never edits code.
- Non-blocking issues / suggestions are follow-ups; they don't block the work.
  Record them in the registry if using one.
- The registry (`.sybil/registry.json`) is used in fanout mode to track
  multi-task state. In-place single-task work typically doesn't need a registry
  entry — the orchestrator's context is sufficient.
