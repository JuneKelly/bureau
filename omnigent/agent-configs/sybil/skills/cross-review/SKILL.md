---
name: cross-review
description: Verify an implementer's diff with `reviewer` (cross-vendor Codex sub-agent); the reviewer gets the diff, the acceptance contract, and its own isolated worktree for full code context. Blocking issues become fix-tasks; loop until clean.
---

# cross-review — independent verification

A different-vendor model signs off, never the implementer. Review is a
sub-agent that returns a structured report, not a transcript anyone reads
through. (The doctrine — why cross-vendor is structural, when `reviewer` is
available — lives in the system prompt; this skill is the procedure.)

## Inputs

Identify from the task context:

- **Reference** — the code state to review: a commit SHA (in-place mode), a
  derived branch `sybil/<topic>/<task_id>` (fanout mode), or a PR URL.
- **Diff** — derived from the reference: SHA → `git show <sha>` or
  `git diff <topic>...<sha>`; branch → `git diff <topic>...<branch>`; PR →
  `gh pr diff <pr>`.
- **Implementer identity** — the `agent` + `title` (or `session_id`) that built
  it, so fix-tasks route back to the same conversation.
- **Acceptance contract** — what the diff must achieve. On a **multi-commit
  reference** keep it **scoped per round**: one criterion per commit / logical
  change, and hand the reviewer ONLY the criteria for the commits present in
  that round's diff. Never re-submit a single whole-branch blob — it forces
  re-litigation of already-verified commits and blurs which criterion a
  blocking issue maps back to.

## Procedure

1. **Get the diff** (see Inputs).
2. **Create an isolated review worktree** at the reference, detached:
   `sys_os_shell("git worktree add --detach .worktrees/review-<task_slug> <reference>")`.
   Detached HEAD avoids conflicting with any existing checkout of the ref. The
   reviewer reads the full code state in a separate working copy; it is
   read-only by design, and any stray writes are contained here and never touch
   the implementer's branch. Record the path.
3. **Run the deterministic gates** (tests / lint / typecheck) via
   `sys_os_shell`. If your environment can't run them, rely on the
   implementer's reported results and have the reviewer focus on logic. If
   gates are runnable and red, re-dispatch the implementer to green first —
   don't involve the reviewer yet; remove the worktree before looping back.
4. **Dispatch `reviewer`** with a task-based title (e.g. `review-<task_slug>`,
   never the raw agent name):
   `sys_session_send(agent="reviewer", title="review-<task_slug>",
   args={purpose: "review", input: "<the diff> + <the acceptance contract>.
   Full code state is at .worktrees/review-<task_slug> — read any file you need
   for context, but review against the diff + contract. Report
   blocking / non-blocking / suggestions. Do not edit code."})`. Give it the
   diff as text AND the review worktree path — **never point it at the
   implementer's working tree** (the independence is the whole point). On a
   multi-commit reference, pass only this round's criteria. Fetch the diff,
   create the worktree, and emit this `sys_session_send` in the SAME turn you
   decide to review — never end a turn on announced intent alone. Then end your
   turn; collect the structured report with `sys_read_inbox` when it returns
   (`sys_session_get_history` only to debug an empty/unclear result).
5. The reviewer **surfaces** issues; it does not fix them. For each **blocking**
   issue, send concrete fixes back to the SAME implementer — reuse its `agent` +
   `title` (or `session_id`) with `purpose: "implement"` so it keeps context
   (record fix-tasks as child bd issues — `$BD create -t task --parent <task>
   … --json`, then `$BD dep add <task> <fix>`). Remove the review worktree,
   then loop to step 1; on the next round scope the contract to the fix
   commit(s) only — don't re-review commits that already passed.
6. **Pass** when gates are green (or trusted from the implementer) AND zero
   blocking issues remain. Non-blocking issues / suggestions are follow-ups,
   not blockers. The deliverable depends on the mode:
   - **In-place:** the commit(s) on the topic branch are verified; the human
     manages any PR and merge.
   - **Fanout:** the derived branch is verified; sybil merges it back to the
     topic branch (per the fanout skill's merge-back step).
7. **Clean up** the review worktree whenever you leave the loop — on pass, and
   before escalating:
   `sys_os_shell("git worktree remove .worktrees/review-<task_slug>")`. If the
   contract can't be satisfied after a few rounds, stop and escalate to the user
   with specifics.

## Notes

- `reviewer` must be AVAILABLE (`codex` on PATH, per the roster preflight). If
  it isn't, you CANNOT run independent cross-vendor review — don't dispatch it,
  say so explicitly, and pull in the human at the plan gate.
- The bd task backend (defined in the system prompt) tracks multi-task state;
  record fix-tasks as child issues (`$BD create -t task --parent <task>`) and
  non-blocking follow-ups as bd notes/issues. In-place single-task work can
  lean on the orchestrator's context, but bd still gives durable, resumable
  state across sessions.
