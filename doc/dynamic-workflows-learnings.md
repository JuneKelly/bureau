# Dynamic workflows in Omnigent — lessons learned from a live run

Status: **empirical findings** from the first end-to-end execution of the
plan-as-code fan-out described in `doc/dynamic-workflows-feasibility.md`.
Companion to that doc, not a replacement.

Relationship to the feasibility doc: that doc is a **static read** — its §10 says
plainly "this design rests on a static read of code on this branch; nothing was
executed." This document records what happened when the pattern was actually run:
a 5-task fan-out to `explorer` workers (expected answers `one`…`five`), driven by a
hand-written `workflow.py` against the live local server. It is the executed
counterpart to that static read, and it updates the `dynamic-workflow` skill that
was generated from the feasibility doc.

Scope caveat (so these lessons are read at the right weight): **one run, 5 tasks,
local single-user server, `explorer` workers only, raw `httpx` against the REST API
(not the `omnigent_client` SDK).** Findings about the *data/access model* generalize;
findings about *scale, caps, and the hardened sandbox* (§3.1 of the feasibility doc)
were **not** exercised and remain as the feasibility doc left them.

---

## TL;DR

- **The core thesis held.** A deterministic program created parented children, fanned
  out in parallel, held all state in its own variables, and the orchestrator only ever
  saw the final synthesized answer. All five workers returned the correct word, each
  mapped to the right task. The feasibility doc's ~90% on the core thesis was right.
- **Every surprise was a *runtime/lifecycle* behavior a static read cannot see.** The
  data model and access model the feasibility doc read directly were accurate. What
  bit us was completion **delivery**, cold-boot **timing**, stream **await semantics**,
  environment **propagation**, and re-run **idempotency** — none observable without
  executing.
- **The headline defect: REST-created parented children can't deliver completion.**
  "Parenting is free" (feasibility §6) is true for *spawn + nesting + read access*, but
  **not** for the parent-inbox completion lifecycle. The result is a silent runner
  retry-storm. This is the single most important thing the static read missed.

---

## 1. What the feasibility doc predicted, confirmed by execution

These held up exactly as the static read claimed:

1. **Plan-as-code works (the thesis).** `asyncio.gather` over per-task coroutines,
   intermediate results in local variables, one synthesized answer posted back. The
   orchestrator's context never saw the fan-out. *(Feasibility §3.4, §10 "high
   confidence" — confirmed.)*
2. **Parenting via the public JSON create is free.** `POST /v1/sessions` with
   `parent_session_id` + `sub_agent_name` created `kind=sub_agent` children that nested
   under the orchestrator in the session tree with zero extra wiring. *(Feasibility §3.3
   / §6 Q1, Q3 — confirmed.)*
3. **Child access is parent-delegated.** The program read each child's status snapshot
   and `items` with no per-child grant — owner access flows from the parent. *(Feasibility
   §6 Q2 — confirmed.)*
4. **Workers can only be spawned parented.** Confirmed the inverse the doc implies:
   `explorer`/`builder`/`drone`/`reviewer` have **no standalone `agent_id`** (they exist
   only inside a parent's spec tree), so a real worker spec resolves *only* via
   `parent_session_id + sub_agent_name`. You cannot run an `explorer` as a top-level
   session. *(This is why the originally-proposed "un-parent the children to dodge the
   storm" option was infeasible — see §3.)*
5. **Local single-user needs no token.** `GET /v1/me` → 200, `accounts_enabled=false`;
   the loopback API accepted unauthenticated requests as `local`. A 401 cleanly signals
   "auth is on, this tier won't work." *(Feasibility §3.2 interim tier — confirmed, and
   simpler than even the "short-lived user token" interim: on local single-user the
   program needs no credential at all.)*

The shipped skill therefore sits squarely at the feasibility doc's **§7 Phase-1 PoC**
tier: real parented fan-out, ambient local access, no hardened sandbox.

---

## 2. What only execution revealed (the lessons)

### 2.1 REST-created parented children cannot deliver completion → runner retry-storm

**The big one.** Feasibility §6 Q2 frames driving a child as "parent-delegated (best
case)" and treats the whole parenting/driving story as free. Execution showed a seam
inside "driving" the static read could not: **read access is free; completion delivery
is not.**

- The parent→child **work entry** that lets a finished child deliver its terminal status
  to the parent inbox is created by `register_subagent_work()` (`runner/app.py:6769`),
  whose **only callers are on the in-runner dispatch path** (`runner/tool_dispatch.py:1402,
  1552`) — i.e. the path `sys_session_send` drives. The server's REST `POST /v1/sessions`
  create **never** registers one.
- So a child spawned over REST runs and finishes correctly, but when the runner tries to
  forward its terminal `idle` status to the parent it is rejected, **repeatedly**:
  ```
  503 {"error":"subagent_delivery_not_confirmed","reason":"missing_work_entry",
       "detail":"Sub-agent terminal status arrived, but the runner has no
                 tracked work entry to deliver to the parent inbox."}
  ```
  Five finished children produced a sustained retry-storm in the runner log that contends
  with live work. It did not corrupt results (the program reads child items directly), but
  it is a real operational wart.

**Lesson.** The feasibility doc's "parenting is a freebie" is correct for *spawn + tree
nesting + read*, and wrong for *inbox completion delivery*. The two are independent
subsystems; a static read of `permissions.py` (access) and `sqlalchemy_store.py` (tree
query) genuinely cannot see the runtime delivery path. Until the create path registers a
work entry, a plan-as-code program **must not depend on inbox delivery** and must read
results by polling child state — which is what the program already did, so the storm is a
log/operational problem, not a correctness one.

### 2.2 "Un-parent to avoid the storm" is infeasible — workers have no standalone agent

The first instinct to kill the storm was to create children **top-level** (no parent →
no parent-delivery → no storm). Execution of the agent registry killed that: there is no
`explorer` `agent_id` to bind a top-level session to (see §1.4). Un-parenting and "run a
real `explorer`" are mutually exclusive on this server. The chosen fix was therefore
**keep children parented, and have the program delete each child as soon as its result is
captured** (a `finally` teardown), so the undeliverable status has no surviving child to
retry against. *(This is a workaround the feasibility doc's design would not need if the
work-entry gap (§2.1) were closed — see §4.)*

### 2.3 Cold-boot timing dominates, and the waiter must be sized for it

Feasibility §8 flags "16 concurrent harness subprocesses is heavy" as a *host-load* risk,
but nothing models the effect on the **waiter's timeout**. Empirically, five `claude`
harnesses cold-booting simultaneously pushed each child's first-turn completion past a
300s per-child cap — the program reported `(timed out)` for all five even though every
child finished correctly moments later. Tells observed: the `/events` ack returned
`{"queued": true, "pending_id": …}` (not the `item_id` a started turn yields), and the
child snapshot showed `host_id: null` initially — i.e. the turn sat **pending** during
cold boot.

**Lesson.** Size the per-child wait as a *generous upper bound* on N harnesses booting at
once (the skill now defaults to 900s), poll on a gentle interval (5s, not 1–2s) to avoid
adding contention, and treat the ack as "queued/pending," not "started."

### 2.4 SSE is not a usable completion signal for a batch waiter

Feasibility §2 and §10 list SSE `stream` as a first-class SDK capability ("SSE streaming
as raw events or semantic blocks"), which reads as "the natural way to await a child."
Execution of the stream route says otherwise:

- `GET /v1/sessions/{id}/stream` is **live-tail only and does NOT replay history**
  (`sessions.py:18697` "Live-tail only … events that fire between are deduped
  client-side"). A waiter that connects *after* the child completes misses the completion
  entirely and hangs.
- Its `idle` query param is a **presence flag** (tab-backgrounded), *not* a completion
  signal (`stream_session(..., idle: bool)` docstring, `sessions.py:18722`).

**Lesson.** For "wait until this freshly-spawned child finishes one turn," **polling the
authoritative snapshot** (`GET /v1/sessions/{id}` → `status`) is the robust primitive; it
has no connect-race. SSE is UI-shaped, not batch-waiter-shaped. (The skill's A#5 was
originally written as "poll via SSE"; the evidence reversed that to "poll the snapshot.")

### 2.5 The launch environment does not carry the parent session id

Feasibility §3.4 step 2 assumes the program is "launched by the runner as a session-scoped
durable task," in which context the orchestrator identity is presumably ambient. The
shipped skill instead launches via `sys_os_shell("python3 …")`, and there the assumption
breaks: `OMNIGENT_SESSION_ID` is set into the runner's **`policy_env`** (`app.py:1126`)
but is **empty in the `sys_os_shell` subprocess** (verified by echo). The original skill's
"discover the single running top-level session" heuristic is also unreliable — the session
list does not expose parent linkage, so it misfires whenever anything else is running.

**Lesson.** Under the `sys_os_shell` launch model, the orchestrator session id **must be
injected explicitly** on the run command (sybil reads it from `sys_session_get_info` and
exports `OMNIGENT_PARENT_SESSION_ID=…`). There is no ambient discovery. This is a real gap
between the feasibility doc's "runner-launched durable task" model and the "agent shells
out" model the skill actually uses.

### 2.6 Re-runs collide on `(parent, title)` and the collision surfaces as a 500

Not addressed in the feasibility doc at all (it never considers idempotency / re-runs).
Sub-agent `(parent, title)` must be unique; re-running with the same titles raised
`NameAlreadyExistsError` (`create_conversation`, conversation store) surfaced to the
client as a generic **500 `internal_error`** rather than a typed 409.

**Lesson.** Use **run-scoped titles** (`wf-{runid}-task-{i}`) so re-runs never collide; and
the server should return a typed `409/conflict` here, not a 500.

### 2.7 Hand-rolling REST re-introduced exactly the wire risk the SDK was meant to absorb

The feasibility doc consistently assumes the program is built on the typed
`omnigent_client` SDK (§2, §7), which encapsulates create / send / stream / items with
correct shapes. The skill template instead hand-rolled raw `httpx` against the REST API —
and inherited two wire-shape bugs the SDK would have hidden:

- The message-post body shape (real `SessionEventInput` is
  `{"type":"message","data":{"role":"user","content":[{"type":"input_text","text":…}]}}`,
  confirmed at `schemas.py` ~1047), and
- The `items` envelope (flat OpenAI-style `{object,data,first_id,last_id,has_more}`,
  message `role`/`content` **top-level**, assistant parts `type:"output_text"`) — *not*
  the nested `item["data"]` shape an earlier guess assumed (that nesting is the
  internal-history view, a different surface).

**Lesson.** Either build on `omnigent_client` as the feasibility doc prescribes (let the
typed client own the shapes), **or**, if hand-rolling REST for zero-dependency simplicity,
treat live wire-shape confirmation against `openapi.json` + the server source as a
*mandatory* step, not advisory. The skill keeps the httpx approach but now hard-codes the
verified shapes and flags the two historically-variable spots.

---

## 3. The meta-lesson

The static read was **accurate on structure and blind on lifecycle.** Everything the
feasibility doc read directly — schemas, the child-listing query, the permission-delegation
check, the presence of `parent_session_id` on the create request — was correct. Every
single thing that bit us in execution was a *dynamic* property no static read surfaces:

| Surprise | Category | Static-read visibility |
|---|---|---|
| `missing_work_entry` delivery storm (§2.1) | runtime delivery path | invisible |
| 300s timeout too short (§2.3) | cold-boot timing | invisible |
| SSE can't signal completion (§2.4) | await semantics + no-replay | partially (route is readable; the *race* is not) |
| `OMNIGENT_SESSION_ID` absent in shell (§2.5) | env propagation | invisible |
| title collision → 500 (§2.6) | re-run idempotency | partially |

This validates the feasibility doc's own §10 caveat and its §8 "to verify in the PoC" list
— and argues that the *next* increment of confidence comes only from execution, not more
reading. A short executed PoC was exactly the right recommended next step; it just needed
to be run to find these.

---

## 4. Corrections folded into the `dynamic-workflow` skill (v2)

The skill at `omnigent/agent-configs/sybil/skills/dynamic-workflow/SKILL.md` was updated in
this session to encode every lesson above:

- **Seed the prompt at create** via `initial_items` (verified field, `schemas.py:1220`;
  dispatched at `sessions.py:11985`) — one POST, no create→start race, no `pending_id`
  ambiguity (§2.3).
- **Read results by polling the snapshot**, not SSE (§2.4); terminal-good is `idle`,
  `failed` surfaces `last_task_error`.
- **Parse the flat OpenAI `items` shape**; correct `SessionEventInput` body (§2.7).
- **Inject `OMNIGENT_PARENT_SESSION_ID` explicitly**; no heuristic discovery (§2.5).
- **Generous 900s wait, 5s poll interval**(§2.3).
- **Run-scoped unique titles** (§2.6).
- **Delete every child in a `finally` (B-1b teardown)** to kill the delivery storm (§2.1,
  §2.2), plus a final sweep.
- **`preflight()` 401 probe** so an auth-enabled server bails loud (§1.5).
- **Fail-loud wire checks**: any non-2xx prints method + URL + request body + response
  body.

---

## 5. Recommendations for the design / a v2 build

Three server-side fixes would let a future version drop the workarounds and realize the
feasibility doc's "parenting is free, children persist and nest" vision honestly:

1. **Register a parent work-entry on REST-created parented children** (or mark them
   "externally tracked, no parent delivery" so forwarding is suppressed). This is the fix
   that removes the §2.1 storm and the §2.2 teardown workaround — children could then nest
   *and* persist *and* deliver. This is the most important follow-up and is **net-new**
   beyond the feasibility doc's gap list (which only flagged caps).
2. **Stop infinitely retrying an undeliverable terminal status.** `missing_work_entry`
   should drop/no-op or back off, not storm.
3. **Return a typed `409` on `(parent, title)` collision**, not a generic 500 (§2.6).

And carry forward the feasibility doc's still-valid open items, now with execution context:

- **Per-run caps** remain genuinely net-new (feasibility §4/§6 Q3). *Not exercised here*
  (5 tasks), so unconfirmed — but nothing observed contradicts the static finding that the
  create path runs no spawn policy.
- **The hardened sandbox (§3.1) is unbuilt.** The shipped skill runs in sybil's own tool
  sandbox with ambient loopback access — the Phase-1 PoC tier. The secretless
  `credential_proxy` + egress-allowlist confinement, and the capability-scoped token, are
  still design-only and still the right target for any multi-user deployment (where the
  §1.5 401 already proves this tier won't run).

---

## 6. Confidence of *this* document

Higher than the feasibility doc on the things it touches, because they were executed — and
silent on the rest:

- **High (observed directly, this session):** the core thesis; parented create + nesting +
  parent-delegated read; the `missing_work_entry` delivery storm; cold-boot timeout
  behavior; SSE no-replay/idle-is-presence; `OMNIGENT_SESSION_ID` absent in shell; title
  collision → 500; the corrected wire shapes; teardown quiesces the storm.
- **Unconfirmed (not exercised):** behavior at scale (≤16 concurrent, hundreds total);
  per-run caps; the hardened egress/credential sandbox; long-run resumability and token
  refresh; non-`explorer` workers; auth-enabled / multi-user servers (only the 401 bail
  path was seen, not a working authenticated run).

A natural next probe: a larger fan-out (closer to the 16-concurrent ceiling) to exercise
caps and host load, and a run that captures child transcripts before teardown to confirm
the persistence/teardown trade-off (§2.2) is acceptable for review-style workflows.
