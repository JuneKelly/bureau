---
name: cross-review
description: Verify an implementer's diff with `reviewer` (cross-vendor Codex sub-agent); the reviewer gets the diff, the acceptance contract, and its own isolated worktree for full code context. Blocking issues become fix-tasks; loop until clean.
---

# cross-review — independent verification

The implementer never signs off on its own work — a different-vendor model
does, and review is a sub-agent that returns a structured report, not a
transcript anyone needs to read through.

## Procedure
1. Get the task's diff — `sys_os_shell("gh pr diff <pr>")` (or
   `git -C .worktrees/<task_id> diff main...HEAD`).
2. Create an isolated review worktree from the implementation branch:
   `sys_os_shell("git worktree add .worktrees/review-<task_id> sybil/<task_id>")`.
   This gives the reviewer full code state in a completely separate working
   copy — any accidental writes are contained here and never touch the
   implementer's branch or PR. Record the review worktree path.
3. Run the deterministic gates first — tests / lint / typecheck via
   `sys_os_shell`. If red, re-dispatch the implementer (`builder` or `drone`,
   whichever built it) to drive it green first; don't involve the reviewer yet.
   Remove the review worktree before looping back
   (`git worktree remove .worktrees/review-<task_id>`), since re-creating
   it after fixes ensures the reviewer always sees the latest committed state.
4. Dispatch `reviewer` for cross-vendor verification. `builder` and `drone`
   always implement with Claude; `reviewer` always reviews with GPT — the
   cross-vendor independence is structural, not a routing decision. Use a
   task-based title such as `review-auth-refactor`, never the raw agent name:
   `sys_session_send(agent="reviewer", title="review-<task_slug>",
   args={purpose: "review", input: "<the diff> + <the acceptance contract>.
   The full code state is at .worktrees/review-<task_id> — read any file you
   need for context, but your review is against the diff + contract. Report
   blocking / non-blocking / suggestions. Do not edit code."})`. Give the
   reviewer the diff as text AND the review worktree path — never point it at
   the implementer's worktree. Fetch the diff, create the review worktree, and
   emit the `sys_session_send` call in the SAME turn you decide to review —
   never end a turn having only announced "I'll load cross-review and fetch
   the diff" with no tool call (that dropped turn stalls the run; nothing
   dispatches and no inbox wake arrives). Once the reviewer dispatch is in
   flight, end your turn; collect the inbox-delivered structured report with
   `sys_read_inbox` when it returns. Use `sys_session_get_history` only to
   debug an empty or unclear review result.
5. The reviewer SURFACES issues; it does not fix them.
6. For each **blocking** issue: add a fix-task to the registry scoped to the
   same worktree, and send the concrete fixes back to the SAME implementer
   (`builder` or `drone`) that built the diff — reuse the original
   implementer's `agent` + `title` (or address it by `session_id`) with
   `purpose: "implement"`, so the worker keeps its worktree/branch context and
   updates its existing PR. A new title would spawn a fresh worker with no
   memory of the task. Remove the review worktree before looping back to
   step 1 — it will be re-created from the updated branch.
7. When gates are green AND there are zero blocking issues, the PR passes
   review — mark it ready in the registry (with its PR URL) and leave it for
   the human to merge. sybil does NOT merge it.
8. Clean up the review worktree:
   `sys_os_shell("git worktree remove .worktrees/review-<task_id>")`.
   Do this after the review loop exits — whether via step 7 (pass) or step 9
   (escalation). The branch lives on the remote; the review worktree is
   disposable.
9. If the contract can't be satisfied after a few loops, stop and escalate to
   the user with specifics. Clean up the review worktree before escalating.

## Notes
- Cross-review requires `reviewer` to be AVAILABLE (per sybil's roster
  preflight — `codex` must be on PATH). If `reviewer` is unavailable, you
  CANNOT run independent cross-vendor review: don't dispatch it, say so
  explicitly, and pull in the human at the plan gate.
- The reviewer gets the diff + contract AND its own isolated review worktree
  (`.worktrees/review-<task_id>`) for full code context. Never point it at the
  implementer's worktree or transcript — the cross-vendor independence is the
  whole point. The review worktree is a separate git working copy checked out
  from the same branch; if the reviewer accidentally writes to it, nothing
  touches the implementer's branch or PR.
- `reviewer` is dispatched with `purpose: "review"`. It reports issues and
  never edits; only the implementer opens a PR, so a stray reviewer edit never
  reaches the deliverable.
- Non-blocking issues / suggestions go in the registry as follow-ups; they
  don't block the PR.
