---
name: dynamic-workflow
description: Run a complex fan-out as a deterministic program instead of turn-by-turn LLM dispatch. Sybil writes a workflow.py that creates parented sub-agent sessions over the local HTTP API, fans them out in parallel, holds all intermediate state in its own variables, and returns only the final synthesized answer — so the orchestrator never has to "think through" the loop. Use for large parallel fan-outs (many similar subtasks, multi-angle drafting, adversarial cross-review at scale). For a handful of parallel implementation tasks, use `fanout` instead.
---

# dynamic-workflow — plan-as-code fan-out

This is the deterministic-program analog of Claude Code's "dynamic workflows".
Where `fanout` dispatches sub-agents **turn by turn** (sybil decides each
`sys_session_send` and holds results in its context), this skill has sybil author
a **single deterministic Python program** that owns the whole loop:

| | `fanout` (agent teams) | `dynamic-workflow` (this skill) |
|---|---|---|
| Who decides what runs next | sybil, each turn | the program |
| Where intermediate results live | sybil's context window | the program's variables |
| Scale | a handful | dozens+ |
| Orchestrator cost | one LLM turn per step | one decision: write + launch |

The program creates **parented** child sessions, so every spawned worker shows up
under sybil in the Subagents panel exactly like a `sys_session_send` child.

## When to use

- A wide fan-out of similar subtasks (e.g. "review each of these 40 files",
  "draft this 6 ways and weigh them", "research these 20 questions in parallel").
- Any pattern where holding all the intermediate results in sybil's context would
  bloat or derail the conversation.

For one-to-a-few parallel *implementation* tasks with worktrees, prefer `fanout`.

## Preconditions (v1)

This v1 is intentionally minimal and assumes the **default local single-user
server**:

1. **Local single-user server.** A bare `omnigent server` / managed-local spawn
   runs single-user with no login (`OMNIGENT_LOCAL_SINGLE_USER`), so the loopback
   REST API accepts requests as the `local` user with **no auth token**. If the
   program gets `401`s, the server has auth enabled — stop and tell the operator;
   this v1 does not handle multi-user auth (that needs the credential-proxy design,
   out of scope here).
2. **Workers are declared sub-agents.** The program spawns workers by
   `sub_agent_name`, resolved from sybil's own spec tree. Sybil's available workers
   are `explorer`, `reviewer`, `builder`, `drone`. Use read-only workers
   (`explorer`, `reviewer`) for research/review fan-outs; only use `builder`/`drone`
   for work that writes, and never in parallel on shared files.
3. **No per-run cap.** Nothing bounds the fan-out for you. **You** are the
   governor: pick a concrete, bounded task count (keep it ≤ ~16 concurrent for a
   single host) and write that bound into the program. Do not author an unbounded
   loop.

## Procedure

1. **Confirm the wire format against the live server.** Before writing the
   program, fetch the running server's schema so the request shapes are exact:
   `sys_os_shell("curl -s http://localhost:6767/openapi.json | python3 -c \"import sys,json; d=json.load(sys.stdin); print(json.dumps(list(d['paths'].keys()),indent=0))\"")`.
   Confirm the request body for `POST /v1/sessions/{id}/events` (how a user message
   is posted) and the response shape of `GET /v1/sessions/{id}/items` (how to read
   the worker's final assistant message). The two spots marked `# ← CONFIRM` in the
   template below are the only ones that vary by version.
2. **Write `workflow.py`** (template below) into a scratch dir, e.g.
   `.sybil/workflows/<slug>.py`. Fill in: the worker `sub_agent_name`, the list of
   per-task prompts, and the synthesis step.
3. **Run it**, capturing the synthesized result:
   `sys_os_shell("python3 .sybil/workflows/<slug>.py")`. The program prints **only**
   the final answer to stdout; the parallel fan-out never enters your context.
4. **Report the synthesized answer** to the operator. The individual worker
   sessions are live under you in the Subagents panel if they want to inspect them.

Do not poll or babysit — the program joins its own children and returns when done.

## `workflow.py` template

```python
#!/usr/bin/env python3
"""Deterministic dynamic-workflow runner. Drives parented sub-agent sessions
over the local Omnigent REST API. Holds all intermediate state here; prints only
the final synthesized answer."""
import asyncio
import os
import httpx

BASE = os.environ.get("OMNIGENT_BASE_URL") or os.environ.get(
    "RUNNER_SERVER_URL", "http://localhost:6767"
).rstrip("/")
# Local single-user: no auth header. (Auth-enabled servers would set this.)
HEADERS = {}
if tok := os.environ.get("OMNIGENT_BEARER"):
    HEADERS["Authorization"] = f"Bearer {tok}"

WORKER = "explorer"          # a sub_agent_name from sybil's spec
MAX_CONCURRENCY = 12         # you are the governor — keep this bounded

# Fill these in for the task at hand:
TASKS: list[str] = [
    # "research question 1 ...",
    # "research question 2 ...",
]


async def find_parent_session(client: httpx.AsyncClient) -> str:
    """The orchestrator (sybil) session id. Overridable; else discover the
    single running top-level session (reliable on single-user local: at launch,
    sybil's is the only running non-sub_agent session)."""
    if pid := os.environ.get("OMNIGENT_PARENT_SESSION_ID"):
        return pid
    r = await client.get(f"{BASE}/v1/sessions", headers=HEADERS)
    r.raise_for_status()
    rows = r.json().get("data", r.json())  # ← CONFIRM list envelope
    running = [
        s for s in rows
        if s.get("status") == "running" and not s.get("parent_session_id")
    ]
    if len(running) != 1:
        raise SystemExit(
            f"could not uniquely identify the orchestrator session "
            f"({len(running)} running top-level sessions); set "
            f"OMNIGENT_PARENT_SESSION_ID"
        )
    return running[0]["id"]


async def spawn_child(client, parent_id: str, agent_id: str, title: str) -> str:
    """Create a PARENTED worker session (kind=sub_agent). Appears under the
    orchestrator for free."""
    r = await client.post(
        f"{BASE}/v1/sessions",
        headers=HEADERS,
        json={
            "agent_id": agent_id,
            "sub_agent_name": WORKER,
            "parent_session_id": parent_id,
            "title": f"{WORKER}:{title}",
        },
    )
    r.raise_for_status()
    return r.json()["id"]


async def run_task(client, sem, parent_id, agent_id, idx, prompt) -> str:
    async with sem:
        child = await spawn_child(client, parent_id, agent_id, f"task-{idx}")
        # Drive one turn with the task prompt.
        await client.post(
            f"{BASE}/v1/sessions/{child}/events",
            headers=HEADERS,
            json={  # ← CONFIRM message-item shape against /openapi.json
                "type": "message",
                "role": "user",
                "content": prompt,
            },
        )
        # Wait for the turn to finish, then read the last assistant message.
        return await collect_result(client, child)


async def collect_result(client, child: str, timeout_s: float = 600.0) -> str:
    """Poll items until the worker's turn completes; return its final text.
    (SSE via GET /v1/sessions/{id}/stream is cleaner; polling keeps v1 simple.)"""
    deadline = asyncio.get_event_loop().time() + timeout_s
    while asyncio.get_event_loop().time() < deadline:
        await asyncio.sleep(3)
        s = await client.get(f"{BASE}/v1/sessions/{child}", headers=HEADERS)
        s.raise_for_status()
        if s.json().get("status") != "running":
            r = await client.get(
                f"{BASE}/v1/sessions/{child}/items", headers=HEADERS
            )
            r.raise_for_status()
            items = r.json().get("data", r.json())  # ← CONFIRM items shape
            texts = [
                it for it in items
                if it.get("type") == "message" and it.get("role") == "assistant"
            ]
            return _text_of(texts[-1]) if texts else ""
    return "(timed out)"


def _text_of(message_item: dict) -> str:
    c = message_item.get("content")
    if isinstance(c, str):
        return c
    if isinstance(c, list):  # content parts
        return "".join(p.get("text", "") for p in c if isinstance(p, dict))
    return str(c)


async def synthesize(results: list[str]) -> str:
    """Plain-code synthesis — or spawn one more worker to weigh the results.
    Kept trivial here; replace with the real reduction for the task."""
    return "\n\n---\n\n".join(
        f"### Task {i}\n{r}" for i, r in enumerate(results)
    )


async def main() -> None:
    if not TASKS:
        raise SystemExit("no TASKS defined")
    async with httpx.AsyncClient(timeout=30.0) as client:
        parent_id = await find_parent_session(client)
        # The child inherits the parent's agent spec tree; the worker's
        # sub_agent_name is resolved against the parent agent.
        pj = (await client.get(
            f"{BASE}/v1/sessions/{parent_id}", headers=HEADERS
        )).json()
        agent_id = pj["agent_id"]
        sem = asyncio.Semaphore(MAX_CONCURRENCY)
        results = await asyncio.gather(*[
            run_task(client, sem, parent_id, agent_id, i, t)
            for i, t in enumerate(TASKS)
        ])
        print(await synthesize(results))


if __name__ == "__main__":
    asyncio.run(main())
```

## What this v1 deliberately does NOT do

- **No security sandbox.** The program runs in sybil's own tool sandbox with
  network access to loopback. Fine for local single-user; the
  egress-proxy/credential design is what makes it safe on a multi-user server.
- **No caps enforcement** (you are the governor — see preconditions).
- **No background/resume.** A long run is tied to the `sys_os_shell` call. Keep
  per-run scope modest; for very long runs, prefer `fanout`.
- **No auth.** Local single-user only. `401` ⇒ stop and tell the operator.

If any of these limits bite, that is the signal to graduate from this v1 skill to
the first-class workflow feature (scoped token, sandbox profile, per-run caps,
durable execution).
