---
name: fanout
description: Run independent subtasks in parallel — one git worktree and one implementation sub-agent per task, each on a branch derived from the topic branch — then cross-review and merge back. Workers don't open PRs; the human manages PR lifecycle.
---

# fanout — parallel execution with derived branches

Opt-in mode for running multiple independent implementation tasks concurrently.
Each task gets its own worktree on a branch derived from the human's topic
branch. Use ONLY for subtasks that are parallel-safe (no shared files, no
ordering dependency). For single tasks or sequential work, use in-place mode
instead (worker operates directly on the topic branch, no worktree needed,
implementation concurrency capped at 1).

## Topic branch

The topic branch is the branch the human operator is working on — it might be
`main`, a feature branch, or anything else. Sybil identifies it by checking
`git branch --show-current` (or the human specifies it). The topic branch is
**human-owned**: sybil never force-pushes, rebases, or resets it. Derived
branches fork from it and merge back to it.

## Procedure

1. **Identify the topic branch** —
   `sys_os_shell("git branch --show-current")`. Record it.
2. **Per task**, create an isolated worktree on a derived branch:
   `sys_os_shell("git worktree add .worktrees/<task_id> -b sybil/<topic>/<task_id>")`
   where `<topic>` is the topic branch name (e.g.
   `sybil/feature-DOC-3201/auth-refactor`). Record the worktree path + branch
   in the registry (`.sybil/registry.json`).
3. **Dispatch one implementation sub-agent per task**, scoped to its worktree:
   `sys_session_send(agent="builder"|"drone", title="<task_slug>",
   args={purpose: "implement", model: "<model>", input: "<task + acceptance
   contract>. Working directory: .worktrees/<task_id>. Branch:
   sybil/<topic>/<task_id>. Commit when done. Do not open a PR."})`.
   Use `builder` (with `args.model: "claude-opus-4-8"`) for substantial
   subtasks and `drone` (with `args.model: "claude-sonnet-4-6"`) for minor
   ones. Use a short task-based title such as `auth-refactor` or
   `fix-sse-error`, never the raw agent name. State the scope and that it must
   work only inside `.worktrees/<task_id>`.
   Every commit the worker authors must end with a blank line followed by the
   exact co-sign trailer as its final line —
   `Co-authored-by: omnigent <noreply@omnigent.ai>`.
   Record each handle's `conversation_id` in the registry. Emit the worktree +
   `sys_session_send` tool calls in THIS turn — never end a turn having only
   said you will dispatch. Dispatch the whole parallel-safe set, THEN (and only
   then) END YOUR TURN. Do not poll.
4. Each sub-agent runs autonomously and notifies you through the inbox when it
   finishes. Collect its structured result with `sys_read_inbox` and record the
   outcome in the registry. If the inbox result is empty/unclear, inspect that
   worker conversation with `sys_session_get_history` before deciding what to
   do next.
5. **Send each finished task through `cross-review`** — pass the derived branch
   name as the reference (see the cross-review skill). The reviewer gets a
   review worktree detached at the derived branch tip.
6. When cross-review passes, **merge the derived branch back to the topic
   branch**:
   ```
   git checkout <topic>
   git merge sybil/<topic>/<task_id> --no-ff -m "merge: <task description>"
   ```
   If the merge has conflicts, **stop and escalate to the human** — sybil does
   not write code, so it cannot resolve conflicts itself. (Alternatively, the
   human may ask sybil to spawn a worker to resolve the conflict, after which
   cross-review runs again on the resolution.)
   Mark the task done in the registry.
7. **Clean up** the finished worktree:
   `sys_os_shell("git worktree remove .worktrees/<task_id>")`
   Only after merge-back is complete. The derived branch can be deleted or left
   for reference — it's plumbing. Don't remove a worktree that still has open
   fix-tasks from cross-review.

## Notes

- **Workers do NOT open PRs.** They commit to their derived branch. PR
  management is the human operator's responsibility — the merged commits
  surface on the topic branch and in any PR the human has open for it.
- Respect the per-turn dispatch cap (enforced by policy). More tasks than the
  cap → dispatch in waves (let the running batch finish before dispatching
  more).
- The human can open any sub-agent in the UI's Subagents panel and read its
  conversation while it runs.
- If a running worker is wrong, runaway, superseded, or no longer useful, call
  `sys_cancel_task` with `task_id` set to the recorded `conversation_id`
  before dispatching a replacement. `builder` and `drone` (claude-native) are
  hard-stopped; `reviewer` (codex-native) cancellation is currently
  best-effort.
- A sub-agent that returns a dark or failing result: don't re-prompt it in a
  loop — re-dispatch a fresh implementation sub-agent in a clean worktree, or
  escalate to the user.
- Keeping each parallel task's file scope disjoint is what keeps merge
  conflicts rare — honor it when decomposing tasks.
