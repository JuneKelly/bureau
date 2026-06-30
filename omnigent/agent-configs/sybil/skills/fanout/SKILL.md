---
name: fanout
description: Run independent subtasks in parallel — one git worktree and one implementation sub-agent per task, each on a branch derived from the topic branch — then cross-review and merge back. Workers don't open PRs; the human manages PR lifecycle.
---

# fanout — parallel execution with derived branches

Opt-in mode for running multiple independent implementation tasks concurrently,
each in its own worktree on a branch derived from the human's topic branch. Use
ONLY for parallel-safe subtasks (no shared files, no ordering dependency). For
single or sequential work, use in-place mode instead (the worker operates
directly on the topic branch, no worktree, implementation concurrency capped
at 1).

## Topic branch

The topic branch is human-owned (see the branch-ownership model in the system
prompt). Identify it with `git branch --show-current` (or take it from the
human). Derived branches fork from it; the step-6 merge-back into it is the ONE
merge sybil performs — at-will, locally, never pushed. Never perform a
cross-scope merge (promoting the topic branch into another branch, or merging an
unrelated branch in/out) without the operator's express permission.

## Procedure

1. **Identify the topic branch** — `sys_os_shell("git branch --show-current")`.
   Record it.
2. **Per task**, create an isolated worktree on a derived branch:
   `sys_os_shell("git worktree add .worktrees/<task_id> -b sybil/<topic>/<task_id>")`
   (e.g. `sybil/feature-DOC-3201/auth-refactor`). Record the worktree path +
   branch in the registry (`.sybil/registry.json`).
3. **Dispatch one implementation sub-agent per task**, scoped to its worktree:
   `sys_session_send(agent="builder"|"drone", title="<task_slug>",
   args={purpose: "implement", model: "<model>", input: "<task + acceptance
   contract>. Working directory: .worktrees/<task_id>. Branch:
   sybil/<topic>/<task_id>. Work ONLY inside that worktree. Commit when done.
   Do not open a PR."})`. Use `builder` (`args.model: "claude-opus-4-8"`) for
   substantial subtasks, `drone` (`args.model: "claude-sonnet-4-6"`) for minor
   ones; use a short task-based title, never the raw agent name. Each commit
   must end with a blank line followed by exactly this trailer as its final
   line — `Co-authored-by: omnigent <noreply@omnigent.ai>`. Record each handle's
   `conversation_id` in the registry. Emit the worktree + `sys_session_send`
   calls THIS turn, dispatch the whole parallel-safe set, THEN end your turn —
   never announce-only, never poll. (More tasks than the per-turn dispatch cap →
   dispatch in waves: let the running batch finish before sending more.)
4. Each sub-agent runs autonomously and notifies you via the inbox. Collect its
   result with `sys_read_inbox` and record the outcome in the registry. If a
   result is empty/unclear, inspect with `sys_session_get_history` before
   deciding; if a worker is wrong / runaway / dark, `sys_cancel_task` on its
   recorded `conversation_id` and re-dispatch a fresh worker in a clean
   worktree (don't re-prompt a dark worker in a loop).
5. **Send each finished task through `cross-review`** — pass the derived branch
   as the reference; the reviewer gets a worktree detached at its tip.
6. When cross-review passes, **merge the derived branch back**:
   ```
   git checkout <topic>
   git merge sybil/<topic>/<task_id> --no-ff -m "merge: <task description>"
   ```
   On conflicts, **stop and escalate to the human** — sybil writes no code, so
   it can't resolve them itself (or, if the human asks, spawn a worker to
   resolve, then re-run cross-review on the resolution). Mark the task done in
   the registry.
7. **Clean up** the worktree only after merge-back is complete:
   `sys_os_shell("git worktree remove .worktrees/<task_id>")`. Don't remove a
   worktree that still has open fix-tasks. The derived branch is plumbing —
   delete it or leave it for reference.

## Notes

- **Workers do NOT open PRs.** They commit to their derived branch; the merged
  commits surface on the topic branch. PR management is the human operator's.
- Keep each parallel task's file scope disjoint — that's what keeps merge
  conflicts rare. Honor it when decomposing tasks.
