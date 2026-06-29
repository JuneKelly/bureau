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
under sybil in the Subagents panel exactly like a `sys_session_send` child — and
**deletes each child as soon as its result is captured** (see "Why teardown"
below).

## When to use

- A wide fan-out of similar subtasks (e.g. "review each of these 40 files",
  "draft this 6 ways and weigh them", "research these 20 questions in parallel").
- Any pattern where holding all the intermediate results in sybil's context would
  bloat or derail the conversation.

For one-to-a-few parallel *implementation* tasks with worktrees, prefer `fanout`.

## Preconditions (v1)

This v1 is intentionally minimal and assumes the **default local single-user
server**:

1. **Local single-user server (no auth).** A bare `omnigent server` / managed-local
   spawn runs single-user with no login, so the loopback REST API accepts requests
   as the `local` user with **no auth token**. The template's `preflight()` probes
   `GET /v1/me`: a `401` means auth is enabled — it stops loud and tells you. This
   v1 does not handle multi-user auth (that needs the credential-proxy design, out
   of scope here).
2. **Workers are declared sub-agents.** The program spawns workers by
   `sub_agent_name`, resolved from sybil's own spec tree. Sybil's available workers
   are `explorer`, `reviewer`, `builder`, `drone`. **They have no standalone
   `agent_id`** — a worker only exists *inside* a parent's spec tree, so children
   MUST be spawned parented (`parent_session_id` + `sub_agent_name`); you cannot run
   a real `explorer` as a top-level session. Use read-only workers (`explorer`,
   `reviewer`) for research/review fan-outs; only use `builder`/`drone` for work
   that writes, and never in parallel on shared files.
3. **The orchestrator session id is injected by sybil, not discovered.** The
   program reads `OMNIGENT_PARENT_SESSION_ID` from its environment — sybil sets it
   on the run command (it gets the value from `sys_session_get_info` on the calling
   session). Do **not** try to auto-discover the parent: the session list does not
   reliably expose parent linkage, and the old "single running top-level session"
   heuristic misfires the moment anything else is running.
4. **No per-run cap.** Nothing bounds the fan-out for you. **You** are the
   governor: pick a concrete, bounded task count (keep it ≤ ~16 concurrent for a
   single host) and write that bound into the program. Do not author an unbounded
   loop.

## Procedure

1. **Re-confirm the wire format against the live server.** The shapes below were
   verified against the server on 2026-06-29; re-confirm if the server version
   changed. Fetch the schema:
   `sys_os_shell("curl -s http://127.0.0.1:6767/openapi.json | python3 -c \"import sys,json; d=json.load(sys.stdin); print('\\n'.join(sorted(d['paths'])))\"")`.
   The two spots that historically vary are marked `# ← VERIFY` in the template.
   Current verified shapes (don't re-guess these unless the schema disagrees):
   - **Seed a task prompt at create time** via `initial_items` on
     `POST /v1/sessions` — one call, no create→start race, no `pending_id`
     ambiguity. Each item is a `SessionEventInput`:
     `{"type":"message","data":{"role":"user","content":[{"type":"input_text","text":"…"}]}}`.
     (`POST /v1/sessions/{id}/events` takes the *same* body shape and is only
     needed to steer an already-running session— the happy path does not use it.)
   - **Read results** from `GET /v1/sessions/{id}/items?order=desc&limit=20`. The
     envelope is OpenAI-style: `{"object","data":[…],"first_id","last_id","has_more"}`.
     Each item is **flat**: `type`, and for messages a **top-level** `role` and
     `content`. Assistant `content` is a list of parts with `type:"output_text"`
     (`{"type":"output_text","text":"…"}`). Role/content are NOT nested under a
     `data` key on this endpoint.
   - **Completion is NOT merely `status != "running"`.** `status` `idle` is
     **overloaded**: a freshly-created REST child reports `idle` *before* its
     seeded turn is dispatched, and reports `idle` again *after* the turn
     finishes. Accept `idle` as terminal **only once the turn has provably run** —
     you observed `status == "running"` at least once, OR an assistant message is
     already present in `/items`. A child stuck in the pre-dispatch `idle` must
     fail **loud** at the timeout, never return an empty "success".
     `status == "failed"` carries `last_task_error`. (The template's
     `wait_and_read` implements exactly this started-gate — do not regress it to
     "first non-running == done".)
2. **Write `workflow.py`** (template below) into a scratch dir, e.g.
   `.sybil/workflows/<slug>.py`. Fill in: the worker `sub_agent_name`, the list of
   per-task prompts, and the synthesis step.
3. **Run it**, injecting your own session id and capturing the synthesized result:
   `sys_os_shell("OMNIGENT_PARENT_SESSION_ID=<your conv id from sys_session_get_info> python3 .sybil/workflows/<slug>.py")`.
   The program prints **only** the final answer to stdout (stderr carries any
   failed request + response body); the parallel fan-out never enters your context.
4. **Report the synthesized answer** to the operator. The program tears down its
   own children, so the Subagents panel returns to clean when it finishes.

> **Validate at N≥3, never at N=1.** This pipeline's worst failure mode — a child
> captured at its pre-dispatch `idle` — is concurrency-timing-dependent: a single
> task almost always wins the dispatch race and looks green, then the *same code*
> loses uniformly at N=12 (every child polled before its turn dispatches). A
> one-task canary gives **false confidence**; smoke-test with at least 3 concurrent
> tasks before trusting a wide fan-out.

Do not poll or babysit — the program joins its own children and returns when done.

### Why teardown (B-1b)

Children created over **raw `POST /v1/sessions`** spawn and run correctly, but the
REST create path does **not** register the parent-side "work entry" that the
in-runner dispatch path (`sys_session_send`) creates. Without that entry, when a
child finishes the runner cannot deliver its terminal status to the parent inbox
and **retries forever** (`subagent_delivery_not_confirmed` / `missing_work_entry`),
producing a runner log storm that contends with live work. This program never
relies on inbox delivery (it reads each child's items directly), so it **deletes
every child in a `finally` the moment its result is captured** — the undeliverable
status has no surviving child to retry against. That is the whole reason teardown
is mandatory here, not optional hygiene.

## `workflow.py` template

```python
#!/usr/bin/env python3
"""Deterministic dynamic-workflow runner (v3). Drives PARENTED sub-agent sessions
over the local Omnigent REST API, fans them out in parallel, holds all
intermediate state here, and prints ONLY the final synthesized answer to stdout.

Design (see SKILL.md for the why):
  * Children are spawned PARENTED (parent_session_id + sub_agent_name) so a real
    worker spec (explorer/reviewer/...) resolves and they nest under the orchestrator.
  * The task prompt is seeded at CREATE time via `initial_items` — one POST, no
    create->start race, no `pending_id` ambiguity.
  * Results are read by POLLING each child's snapshot status + items. NOT SSE:
    GET /stream is a live tail that does NOT replay history (and its `idle` flag is
    a presence flag, not a completion signal), so an SSE waiter that connects after
    completion misses it and hangs. Re-reading the snapshot has no connect-race.
  * Status 'idle' is AMBIGUOUS: a freshly-created REST child reports 'idle' BEFORE
    its seeded turn is dispatched, and 'idle' again AFTER it finishes. wait_and_read
    accepts 'idle' as terminal ONLY once the turn provably ran (it saw 'running', or
    an assistant message exists); otherwise it keeps polling and fails loud at the
    deadline. Treating the FIRST 'idle' as done silently returns empty results and
    loses uniformly under concurrency (N=1 wins the dispatch race; N=12 loses it).
  * Every spawned child is DELETED in a `finally` as soon as its result is captured
    (B-1b teardown), so undeliverable terminal-status retries can't storm the runner.
"""
import asyncio
import os
import sys
import time
import uuid
import httpx

BASE = (
    os.environ.get("OMNIGENT_BASE_URL")
    or os.environ.get("RUNNER_SERVER_URL")
    or "http://127.0.0.1:6767"
).rstrip("/")

# Local single-user => no auth header. Auth-enabled servers are unsupported here
# (preflight() bails on 401).
HEADERS: dict[str, str] = {}
if tok := os.environ.get("OMNIGENT_BEARER"):
    HEADERS["Authorization"] = f"Bearer {tok}"

# Orchestrator (sybil) session id — REQUIRED, injected by sybil on the run command
# (read from sys_session_get_info). No heuristic discovery.
PARENT_SESSION_ID = os.environ.get("OMNIGENT_PARENT_SESSION_ID", "").strip()

WORKER = "explorer"           # a sub_agent_name from sybil's spec tree
MAX_CONCURRENCY = 12          # you are the governor — keep bounded (<= ~16)
PER_CHILD_TIMEOUT_S = 900.0   # generous: N cold-booting harnesses are slow
POLL_INTERVAL_S = 5.0         # gentle on the runner; do NOT hammer at 1-2s
RUN_ID = uuid.uuid4().hex[:8]  # run-scoped => (parent,title) never collides

# Fill these in for the task at hand:
TASKS: list[str] = [
    # "research question 1 ...",
    # "research question 2 ...",
]

SPAWNED: set[str] = set()  # ids of live children, for a belt-and-suspenders sweep


class WireError(RuntimeError):
    """A non-2xx (or stuck/timeout), carrying the full request+response."""


def _check(resp: httpx.Response, *, method: str, url: str, body=None) -> httpx.Response:
    if resp.is_success:
        return resp
    raise WireError(
        f"\n  {method} {url}\n  request body: {body!r}\n"
        f"  -> {resp.status_code} {resp.reason_phrase}\n  response body: {resp.text}"
    )


def _message_item(text: str) -> dict:
    """A SessionEventInput of type 'message' (verified shape)."""
    return {  # ← VERIFY: message-item shape against /openapi.json
        "type": "message",
        "data": {"role": "user", "content": [{"type": "input_text", "text": text}]},
    }


async def preflight(client: httpx.AsyncClient) -> None:
    r = await client.get(f"{BASE}/v1/me", headers=HEADERS)
    if r.status_code == 401:
        raise SystemExit(
            "401 from /v1/me: this server has auth enabled. This v1 supports only "
            "the local single-user server (no token). Stop and tell the operator."
        )
    _check(r, method="GET", url=f"{BASE}/v1/me")
    if not PARENT_SESSION_ID:
        raise SystemExit(
            "OMNIGENT_PARENT_SESSION_ID is unset. Sybil must inject the orchestrator "
            "session id on the run command, e.g.:\n"
            "  OMNIGENT_PARENT_SESSION_ID=conv_xxx python3 workflow.py"
        )


async def parent_agent_id(client: httpx.AsyncClient) -> str:
    url = f"{BASE}/v1/sessions/{PARENT_SESSION_ID}"
    r = _check(await client.get(url, headers=HEADERS), method="GET", url=url)
    return r.json()["agent_id"]


async def spawn_child(client, agent_id: str, idx: int, prompt: str) -> str:
    """Create a PARENTED worker session, seeding the task prompt at create time."""
    body = {
        "agent_id": agent_id,
        "sub_agent_name": WORKER,
        "parent_session_id": PARENT_SESSION_ID,
        "title": f"wf-{RUN_ID}-task-{idx + 1}",  # run-scoped: avoids NameAlreadyExists
        "initial_items": [_message_item(prompt)],
    }
    url = f"{BASE}/v1/sessions"
    r = _check(await client.post(url, headers=HEADERS, json=body),
               method="POST", url=url, body=body)
    child = r.json()["id"]
    SPAWNED.add(child)
    return child


async def delete_child(client, child: str) -> None:
    """Best-effort teardown (B-1b). Never raises — cleanup must not mask results."""
    try:
        await client.delete(f"{BASE}/v1/sessions/{child}", headers=HEADERS)
    except Exception as exc:  # noqa: BLE001
        print(f"--> warn: failed to delete child {child}: {exc}", file=sys.stderr)
    finally:
        SPAWNED.discard(child)


def _assistant_text(items: list[dict]) -> str:
    """Last assistant message's text. REST /items is flat OpenAI-style: role/content
    are TOP-LEVEL; assistant content parts are 'output_text'. Items passed newest-first."""
    for it in items:  # ← VERIFY: items envelope/shape against /openapi.json
        if it.get("type") == "message" and it.get("role") == "assistant":
            c = it.get("content")
            if isinstance(c, str):
                return c
            if isinstance(c,list):
                return "".join(
                    p.get("text", "")
                    for p in c
                    if isinstance(p, dict) and p.get("type") in ("output_text", "text")
                )
    return ""


async def wait_and_read(client, child: str) -> str:
    """Poll the child's snapshot until its seeded turn has DEMONSTRABLY run, then
    read the final assistant text.

    Why not "first non-running status == done"? A freshly-created REST child
    reports status 'idle' BEFORE its seeded turn is dispatched, and 'idle' again
    AFTER it finishes -- 'idle' is overloaded. Treating the first 'idle' as
    terminal (the v2 bug) captures an inert child (only the seed, no assistant,
    0 tokens, host_id None) and returns '' SILENTLY; under concurrency this loses
    uniformly (N=1 wins the dispatch race, N=12 loses it). So accept 'idle' as
    terminal ONLY once the turn provably ran: we observed 'running', OR an
    assistant message already exists. A child that never dispatches bottoms out at
    the deadline and fails LOUD instead of as an empty 'success'.
    """
    deadline = time.monotonic() + PER_CHILD_TIMEOUT_S
    saw_running = False
    while time.monotonic() < deadline:
        await asyncio.sleep(POLL_INTERVAL_S)
        url = f"{BASE}/v1/sessions/{child}"
        snap = _check(await client.get(url, headers=HEADERS), method="GET", url=url).json()
        status = snap.get("status")
        if status == "running":
            saw_running = True
            continue
        if status == "failed":
            raise WireError(
                f"child {child} failed: {snap.get('last_task_error') or '(no detail)'}"
            )
        # Non-running, non-failed (typically 'idle'): disambiguate not-started vs done.
        items_url = f"{BASE}/v1/sessions/{child}/items?order=desc&limit=20"
        r = _check(await client.get(items_url, headers=HEADERS), method="GET", url=items_url)
        text = _assistant_text(r.json().get("data", []))
        if text or saw_running:
            return text
        # Pre-dispatch 'idle': the seeded turn hasn't started yet -- keep polling.
    raise WireError(
        f"child {child} never ran its seeded turn within {PER_CHILD_TIMEOUT_S:.0f}s "
        "(stuck in pre-dispatch 'idle'; see the REST-create work-entry wart below)"
    )


async def run_task(client, sem, agent_id, idx, prompt) -> str:
    async with sem:
        child = await spawn_child(client, agent_id, idx, prompt)
        try:
            return await wait_and_read(client, child)
        finally:
            await delete_child(client, child)  # B-1b: teardown the moment we're done


def synthesize(results: list[str]) -> str:
    """Plain-code reduction. Replace with the real synthesis for the task."""
    return "\n\n---\n\n".join(f"### Task {i + 1}\n{r}" for i, r in enumerate(results))


async def main() -> None:
    if not TASKS:
        raise SystemExit("no TASKS defined")
    async with httpx.AsyncClient(timeout=30.0) as client:
        await preflight(client)
        agent_id = await parent_agent_id(client)
        sem = asyncio.Semaphore(MAX_CONCURRENCY)
        try:
            outcomes = await asyncio.gather(
                *(run_task(client, sem, agent_id, i, t) for i, t in enumerate(TASKS)),
                return_exceptions=True,  # let every task run its own teardown finally
            )
        finally:
            for child in list(SPAWNED):  # sweep anything a failure left behind
                await delete_child(client, child)

    failures = [(i, o) for i, o in enumerate(outcomes) if isinstance(o, Exception)]
    if failures:
        for i, exc in failures:
            print(f"--> TASK {i + 1} FAILED: {exc}", file=sys.stderr)
        raise SystemExit(f"{len(failures)}/{len(TASKS)} task(s) failed (see stderr)")
    print(synthesize(list(outcomes)))


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
- **No SSE await.** `GET /v1/sessions/{id}/stream` is a UI-oriented live tail with
  no history replay (its `idle` param is a presence flag, not completion), so it
  has a connect-race that a batch waiter must not rely on. We poll the snapshot.
- **No auth.** Local single-user only. `401` ⇒ stop and tell the operator.
- **No persisted child transcripts.** Teardown deletes each child when done. If you
  need the workers' full transcripts after the run, capture them in the program
  before `delete_child` (e.g. write items to disk) — the default keeps the tree clean.

## Known server warts worth filing (so a v2 can drop the workarounds)

- **`status` `idle` is overloaded** (pre-dispatch vs finished), so completion
  cannot be read from status alone — the client must gate on "the turn provably
  ran" (saw `running`, or an assistant message exists). A distinct
  `created`/`queued` state emitted before first dispatch would let clients tell
  "not started" from "done" directly, and drop the started-gate workaround.
- **REST-created parented children get no parent work-entry.** `register_subagent_work()`
  is only called on the in-runner dispatch path, so REST-spawned parented children
  can't deliver terminal status and the runner retry-storms (`missing_work_entry`).
  Fix upstream: register a work entry on REST create, OR mark such children
  "externally tracked, no parent delivery" so forwarding is suppressed — then this
  skill could keep children parented *and* persisted without teardown.
- **The runner retries an undeliverable terminal status indefinitely.**
  `missing_work_entry` should drop/no-op or back off, not storm.
- **A sub-agent title collision returns 500, not 409.** Re-running with a duplicate
  `(parent, title)` raises `NameAlreadyExistsError` surfaced as a generic
  `internal_error`. Run-scoped titles dodge it here; the server should return a
  typed `409`/`conflict` instead.

If any of the "does NOT" limits bite, that is the signal to graduate from this v1
skill to the first-class workflow feature (scoped token, sandbox profile, per-run
caps, durable execution, and a real registered work-entry so children both nest
and deliver).
