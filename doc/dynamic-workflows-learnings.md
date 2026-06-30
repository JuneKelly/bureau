# Dynamic workflows in Omnigent — lessons learned from a live run

Status: **empirical findings** from end-to-end executions of the
plan-as-code fan-out described in `doc/dynamic-workflows-feasibility.md`.
Companion to that doc, not a replacement. §11 adds a **faithfulness audit** of
the shipped skill against the stated goal — a different lens from the execution
runs in §1–§10 (it grades the artifact, it does not flush a runtime defect).

> **Three execution sessions are recorded here.** Session 1 (below, §1–§6) was a
> 5-task fan-out that flushed the *delivery/timing/wire* pack and produced the
> **v2** skill. Session 2 (§7) re-ran the fan-out **at N=12**, flushed the next
> pack — a concurrency-timing **`idle`-overload race** that a one-task canary
> cannot see — and produced the **v3** started-gate fix, confirmed green (12/12).
> Session 3 (§9) ran a real substantive N=5 fan-out **with persistence on** against
> the Fix-4 server, flushed the *finish-edge* pack — the **`idle` settle-race**
> (§2.9) and **empty-`str()` transport errors** (§2.10) — and produced the **v5**
> skill, with all four persistence success signals green. Read §9 for the current
> state; §7 and §1–§6 are the still-valid earlier records.

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

**Status update (Session 3): the storm is FIXED at the runner (Fix 4); persistence is now
the default.** A non-deliverable terminal status is now **204-acknowledged** instead of
503-returned, so a surviving completed child no longer storms the log. The work-entry is
still not registered on REST create (so inbox *delivery* still doesn't happen — the program
reads child items directly, exactly as before), but children can now safely **persist** after
the run. The v5 skill sets `TEARDOWN = False` by default; teardown is opt-in for throwaway runs.

### 2.2 "Un-parent to avoid the storm" is infeasible — workers have no standalone agent

The first instinct to kill the storm was to create children **top-level** (no parent →
no parent-delivery → no storm). Execution of the agent registry killed that: there is no
`explorer` `agent_id` to bind a top-level session to (see §1.4). Un-parenting and "run a
real `explorer`" are mutually exclusive on this server. The chosen fix was therefore
**keep children parented, and have the program delete each child as soon as its result is
captured** (a `finally` teardown), so the undeliverable status has no surviving child to
retry against. *(This is a workaround the feasibility doc's design would not need if the
work-entry gap (§2.1) were closed — see §4.)*

**Reframe (Session 3): teardown is no longer mandatory.** That delete-each-child workaround
was only needed because the undeliverable status used to storm (§2.1). With Fix 4 the storm
is gone, so keeping children parented **and alive** is safe — exactly what the v5 skill does
by default (`TEARDOWN = False`), preserving every worker's transcript in the Subagents panel.
Teardown survives only as an opt-in for throwaway fan-outs that want the tree to return clean.

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

### 2.8 `status` `idle` is overloaded — completion can't be read from status alone (found at N=12, Session 2)

The single biggest Session-2 finding, and a *pure* concurrency-timing defect that the
5-task Session-1 run never exposed. The v2 skill's `wait_and_read` treated the **first**
non-`running` status as "done" — and `idle` is **overloaded**: a freshly-created REST child
reports `idle` *before* its seeded turn is dispatched, **and** `idle` again *after* the turn
finishes. At N=12 the poller caught all twelve children at their **pre-dispatch `idle`**,
captured inert shells (only the seed item, **0 assistant messages, `last_total_tokens` /
`total_cost_usd` = `None`, `host_id` = `None`, `last_task_error` = `None`** — it fails
*silently*), returned `""`, and deleted them. **Result: 0/12 answers — not a model failure;
the workflow declared victory before the work started.**

**Why Session 1 missed it.** N=1 (and even N=5, on a warm host) almost always *wins* the
dispatch race — the child has begun running by the time the first poll lands, so the first
observed status is already `running`/post-run. The *same code* loses **uniformly** at N=12,
where every child is polled in the window before its turn dispatches. **Meta-finding: a
one-task canary cannot validate a concurrency pipeline** — the worst failure mode is
timing-dependent and a single task hides it. (Confirmed by direct contrast: the Session-1
N=1 canary genuinely ran — 17,230 tokens, returned `'one'`; the v2 N=12 run failed all twelve.)

**The fix (v3 started-gate).** Accept `idle` as terminal **only once the turn provably ran**:
the poller observed `status == "running"` at least once, OR an assistant message is already
present in `/items`. A child stuck in pre-dispatch `idle` keeps polling and **fails loud at
the deadline** instead of returning an empty "success." See §7 for the confirming re-run.

**Lesson.** Completion is a *started-and-finished* predicate, not a single status read. Any
client of this REST surface must implement a started-gate until the server emits a distinct
pre-dispatch state (see §5 recommendation 4). And validate fan-out pipelines at **N≥3**, never
N=1.

### 2.9 The `idle` settle-race: status flips to `idle` BEFORE the answer is queryable (Session 3)

A second, *trailing-edge* face of the §2.8 `idle` overload, found running a real N=5
`explorer` fan-out (substantive multi-paragraph research, not the one-word toy). The v3/v4
started-gate accepted `idle` as terminal once the turn had **provably run** (saw `running`,
or an assistant message exists). But a child's `status` flips back to `idle` a few seconds
**before** its assistant message and token accounting commit to `/items`. So a waiter that
returns on "saw `running` + status idle" can read `/items` in that gap, find **no assistant
message yet**, and return `""` — the same silent-empty-success class as §2.8, now from the
*finish* side instead of the *dispatch* side. Observed directly: the first N=5 run returned
an all-empty synthesis, yet re-reading each child moments later showed a genuine ~31k-token
assistant answer that had simply not been queryable at read time.

**The fix (v5).** The completion signal is the **presence of assistant text**, not the
status flip. `wait_and_read` now keeps polling while there is no assistant text — whether the
child is pre-dispatch *or* finished-but-settling — and only the deadline ends the loop
(loud). `saw_running` is demoted to deadline-message detail. Re-running with this fix turned
the all-empty synthesis into a correct 5/5.

**Lesson.** "The turn ran" and "the turn's output is readable" are *different* events with a
few-seconds gap; gate on the artifact you actually need (assistant text), never on a status
proxy. A server fix — commit the assistant message atomically with the status flip, or emit
a distinct terminal state only once items are durable — would let clients drop this gate.

### 2.10 Transport errors during polling are transient and have an empty `str()` (Session 3)

The same N=5 run surfaced a client-robustness trap. With the per-request `httpx` client
timeout at 30s, one poll request stalled past it while five harnesses cold-booted and
saturated the host, raising a bare `httpx.ReadError('')`. Two nasty properties compounded:
(a) it is **not** a `WireError`, so it bypassed the fail-loud wrapper, and (b) its `str()` is
**empty**, so it failed a whole task with the blank message `--> TASK 5 FAILED:` — maximally
unhelpful. The child itself had run fine on the server.

**The fix (v5).** Bump the client timeout to 60s, and treat `httpx.HTTPError` *during
polling* as transient: log a one-line warning and keep polling (the next poll re-reads the
authoritative snapshot; only the deadline ends the loop). Genuine server errors still surface
as `WireError` — which is not an `httpx.HTTPError` — and still fail loud. The confirming run
caught exactly one `ReadError('')`, recovered, and the task still returned its answer.

**Lesson.** Under concurrent cold-boot load, transport-level errors are expected noise, not
task failure; a batch waiter must distinguish *transport* faults (retry) from *server* faults
(fail loud), and must never let an exception with an empty `str()` masquerade as a silent
failure.

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
| `idle` overloaded → first-idle-wins race (§2.8, Session 2) | concurrency-timing / status semantics | invisible (needs N≥3 to even surface) |
| `idle` settle-race: status flips before items commit (§2.9, Session 3) | runtime write-ordering / eventual consistency | invisible |
| bare empty-`str()` transport error under cold-boot load (§2.10, Session 3) | client transport timing | invisible |

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

### 4.1 Folded in Session 2 (v3)

- **Started-gate in `wait_and_read`** (§2.8): accept `idle` as terminal only after the turn
  provably ran (saw `running`, or an assistant message exists); a never-dispatched child
  **fails loud at the deadline** rather than returning an empty success. The Procedure now
  states "Completion is NOT merely `status != \"running\"`" and carries a **"Validate at
  N≥3, never N=1"** callout; the template docstring is bumped to `v3` and gains an "`idle`
  is overloaded" platform-wart note.

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

4. **Emit a distinct pre-dispatch state** (e.g. `created`/`queued`) before a child's first
   turn dispatches, so clients can tell "not started" from "done" directly and drop the
   §2.8 started-gate workaround. This is **net-new from Session 2**; today `idle` conflates
   both.

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

- **High (observed directly, Session 1):** the core thesis; parented create + nesting +
  parent-delegated read; the `missing_work_entry` delivery storm; cold-boot timeout
  behavior; SSE no-replay/idle-is-presence; `OMNIGENT_SESSION_ID` absent in shell; title
  collision → 500; the corrected wire shapes; teardown quiesces the storm.
- **High (observed directly, Session 2):** the `idle`-overload first-idle-wins race at N=12
  (§2.8); the v3 started-gate closes it; **a concurrency pipeline at N=12 runs correctly
  and uniformly** (12/12, each child a real assistant turn at ~17.7k tokens — see §7);
  capture-before-teardown is a working forensic primitive; teardown leaves no orphans at
  N=12 (deleted child → 404, parent `child_sessions` → 0).
- **Unconfirmed (not exercised):** behavior at the upper ceiling (toward 16 concurrent,
  hundreds total); per-run caps; the hardened egress/credential sandbox; long-run
  resumability and token refresh; non-`explorer` workers; auth-enabled / multi-user servers
  (only the 401 bail path was seen, not a working authenticated run).

The "natural next probe" Session 1 proposed — a wider fan-out that captures child
transcripts before teardown — **was Session 2** (§7); it confirmed the persistence/teardown
trade-off (§2.2) is fine for review-style workflows and flushed the §2.8 race. The next
probe from here pushes toward the 16-concurrent ceiling to exercise caps and host load.

---

## 7. Session 2: the N=12 confirming re-run (v3 started-gate)

**Setup.** Probe regenerated **from the v3 template** (the v2 `probe12.py` was *not* reused —
it still carried the first-idle-wins poller), 12 throwaway `explorer` children each seeded
`"reply with ONLY the lowercase english word for {i}"`, parent session id injected via
`OMNIGENT_PARENT_SESSION_ID`, capture-before-teardown retained. Pre-run gates all green:
server `GET /v1/me` → 200; the Skill tool served **v3** (docstring `runner (v3)`,
`saw_running` started-gate, the N≥3 callout); `POST /v1/sessions` create body re-confirmed
against the live `openapi.json` (the create body is hidden from the schema, so it was taken
as empirically proven from Session 1's successful creates).

**Result: 12/12 correct** (`one`…`twelve`), exit 0. Per-child captures show the
**genuine-run signature** uniformly — exactly **1 assistant message** and **~17,700 tokens**
each (consistent with Session 1's working N=1 canary at 17,230; the precise inverse of the
v2 inert signature of 0 assistant messages / `None` tokens). Teardown verified clean: a
deleted child returns **404** and the parent's `child_sessions` lists **0** — no orphans.

| Metric | v2 at N=12 (Session 1 diagnosis) | v3 at N=12 (Session 2) |
|---|---|---|
| Correct words | 0/12 | **12/12** |
| Assistant msgs / child | 0 (inert) | **1** |
| Tokens / child | `None` | **~17,700** |
| Failure mode | silent empty "success" | n/a (would now time out **loud**) |
| Orphans after run | none (teardown fired) | **none** (404 / 0 children) |

**What this nails down.** The race in §2.8 is closed: every child was polled past its
pre-dispatch `idle` until its seeded turn provably ran. The started-gate is not just
defensive — it converts the worst-case (a never-dispatched child) from a silent `0/N` into
a **loud timeout**, so a future genuine stall is detectable rather than papered over. One
benign capture note: `host_id` reads `None` in the *post-run* snapshot because the host
releases when the turn finishes; the decisive "it ran" signals are the assistant message
and the token count, both solid across all 12.

---

## 8. Viability verdict — are Claude-Code-style dynamic workflows viable in Omnigent?

**Yes, in three tiers — and Tier 1 is now proven *and* concurrency-verified.**

- **Tier 1 — local read-only fan-out (the shipped v5 skill): VIABLE, verified.** The
  mechanism (parented create → seed-at-create → parallel poll → capture) works, and after
  the started-gate (v3) plus the settle-race + transient-error fixes (v5, §2.9/§2.10) it
  works **correctly under concurrency** — at N=12 (Session 2) and at N=5 with persistence on
  (Session 3) — not just at the N=1 canary that gave false confidence (§2.8, §7, §9). The
  honest caveats are scope, not soundness: validated to N=12 (not yet the ~16 ceiling),
  `explorer`-only, local single-user, no caps enforcement, run tied to one `sys_os_shell`
  call (no background/resume). For wide read-only fan-outs on a local box, it is usable today.
- **Tier 2 — persistent nested children, robust locally: DONE (persistence verified at N=5,
  Session 3).** The storm that made teardown mandatory is fixed at the runner (Fix 4, §2.1):
  a non-deliverable terminal status is now 204-acknowledged, so children **nest *and*
  persist** safely. Verified end to end at N=5 with the v5 skill (`TEARDOWN = False`): all
  five children survived in `child_sessions`, zero storm signatures in the runner log, and
  each was a genuine ~31k-token assistant turn (§9). The one remaining gap is delivery-only:
  REST create still registers no parent work-entry, so inbox *delivery* doesn't fire — the
  program reads items directly instead. Closing that (register a work-entry on REST create,
  or mark such children "externally tracked") would let children deliver too, not just
  persist; persistence itself no longer needs it.
- **Tier 3 — secure / multi-user / at-scale: DEFERRABLE, designed but unexercised.** The
  hardened sandbox (credential-proxy + egress allowlist, capability-scoped token) from
  feasibility §3.1 is design-only; the §1.5 401-bail proves Tier 1 won't run multi-user as-is.
  Right target for any shared deployment, not needed for the local single-user use case the
  skill serves.

**Bottom line.** The meta-lesson holds end to end: *the static read was flawless on
structure, blind on lifecycle, and lifecycle surprises travel in packs.* Session 1 flushed
the delivery/timing/wire pack; Session 2's N=12 run flushed the dispatch-edge `idle` race
**exactly as the "validate at N≥3" instinct predicted**; Session 3's N=5 persistence run
flushed the finish-edge pack (the §2.9 settle-race + §2.10 transport noise) and proved
children nest *and* persist with the storm fixed. The remaining build is the REST-create
work-entry so children *deliver* too (not just persist); the next *probe* is a push toward
the concurrency ceiling.

---

## 9. Session 3: persistence verified at N=5 (v5 settle-race + transient-error fixes)

**Setup.** The next-session goal from the handoff: run a *real*, substantive fan-out with
**persistence on** against the Fix-4 server. Authored a fresh `workflow.py` from the v4
template at `.sybil/workflows/persistence-test.py` — N=5 `explorer` children, each seeded a
genuine multi-paragraph design-research question (single-host fan-out failure modes; polling
vs. SSE; overloaded status values; per-run caps; idempotent re-runs), `TEARDOWN = False`,
parent id injected via `OMNIGENT_PARENT_SESSION_ID`. Roster full (Claude + Codex); server
`GET /v1/me` → 200 (local single-user).

**Two defects flushed, both client-side (see §2.9, §2.10).** The first run spawned and ran
all five children correctly but returned an **all-empty synthesis** — the §2.9 settle-race
(status flips to `idle` before the answer is queryable; the v4 "saw running" gate returned
`""`). Fixing the completion signal to "assistant text present" exposed the second: one task
died with a blank message — the §2.10 bare `ReadError('')` from a 30s poll timeout under
cold-boot load. Fixed with a 60s client timeout + transient-`httpx.HTTPError` tolerance.

**Result: 5/5, all four success signals green (v5).**

| Signal | Result |
|---|---|
| Children persist | ✅ `GET /v1/sessions/{parent}/child_sessions` lists all 5 (none deleted); nested in the Subagents panel |
| No runner storm | ✅ 0 `missing_work_entry` / `subagent_delivery_not_confirmed` / `missing_parent_inbox`, 0 `503` in the runner log (Fix 4 holding) |
| Genuine-run signature | ✅ every child `idle`, **~30.6–31.5k tokens**, 1 assistant message, `last_task_error` None |
| Correct synthesized output | ✅ full 5-section synthesis returned to the orchestrator; the fan-out never entered sybil's context |

The confirming run also exercised §2.10 live: one transient `ReadError('')` was caught and
recovered, and that task still returned. Validated at **N=5** (≥3, per the §2.8 rule);
children left **up** by design (the persistence proof) and swept manually afterward.

**What this nails down.** Tier-1 persistence is real: with Fix 4 the storm is gone, so
REST-spawned parented children **nest and persist** safely, and the v5 skill defaults to
keeping them. The two new findings (§2.9, §2.10) are both *client-lifecycle* surprises a
static read could never show — consistent with the meta-lesson and with "lifecycle surprises
travel in packs": Session 1 flushed delivery/timing/wire, Session 2 the dispatch-edge `idle`
race, Session 3 the finish-edge settle-race + transport noise. The remaining Tier-2 gap is
delivery-only (REST create still registers no work-entry); persistence no longer needs it.

---

## 10. Session 4: a lean joke fan-out — and the orchestrator-ceremony lesson

**Setup.** A throwaway "run another workflow test" at the operator's request: N=4 `explorer`
children, each seeded a tight prompt to invent one original short joke on a distinct theme
(programming / animals / outer space / coffee), `TEARDOWN = False`, parent id injected via
`OMNIGENT_PARENT_SESSION_ID`. Server this session was `http://127.0.0.1:6767` (the base URL is
NOT fixed — read `$RUNNER_SERVER_URL`; Session 3 was `54533`), `GET /v1/me` → 200 (local
single-user). v5 template, unchanged. Run via `uv run --with httpx python3 …` (httpx still not
preinstalled).

**Result: 4/4, green on every signal, first try.** Each child returned a real joke mapped to
its theme; the program printed only the synthesized 4-section set (the fan-out never entered
the orchestrator's context). Per-child genuine-run signature held uniformly: all `idle`,
**~30.6–31.5k tokens**, 1 assistant message, `last_task_error` None; all four persisted in
`child_sessions`; **0** storm signatures in the runner log (Fix 4 holding). No new *pipeline*
defect — the v5 template ran exactly as documented at N=4 (≥3, per the §2.8 rule).

**The finding this session is about the ORCHESTRATOR, not the program.** The run worked, but
sybil wrapped it in ceremony that defeats the point of plan-as-code: a manual `curl /v1/me` +
openapi-paths dump *before* launch (duplicating the program's own `preflight()`), and **three**
post-run shell calls (a `child_sessions` count, a per-child token/`status` snapshot, a
runner-log storm grep) — two of which broke on shell-quoting and needed retries — plus
narration between each. That is precisely the turn-by-turn, state-in-the-orchestrator's-context
mode the skill exists to replace; the program's clean stdout + exit 0 was already the proof of
success. The verification reflex is a hangover from Sessions 1–3, where every run was *flushing
lifecycle bugs* — but that is QA **of the pipeline**, not **running** a workflow. On a
known-good v5 server it is pure context bloat.

**The fix (skill prose, this session).** Added a **"Run lean — keep the orchestrator quiet"**
subsection to `dynamic-workflow/SKILL.md`: a faithful run is ~3 tool calls (read own session id
→ author → launch + report stdout), with three explicit ceremony traps to resist (don't
re-validate the skill on a known-good server; don't duplicate `preflight()`; don't narrate each
step), and the note that this v1's `sys_os_shell` launch *blocks*, so the blocking call **is**
the wait — there is nothing to poll. Also fixed a stale step-4 line that still claimed "the
program tears down its own children" (false since persistence became the v5 default).

**Lesson.** The pipeline is mature enough (v5; Tier-1 verified; Tier-2 persistence verified)
that the dominant remaining inefficiency is no longer a *client/runtime* defect but
**orchestrator discipline**: post-bug-flushing, the operator must stop QA-ing the pipeline on
every run and let the program be the program. Verify only on a loud failure (non-zero exit / a
`--> TASK n FAILED` on stderr). This is the first lesson here that targets sybil's own behavior
rather than the REST surface or the template.

---

## 11. Session 5: faithfulness audit — is the shipped skill a "close replica" of Claude Code dynamic workflows?

**Setup.** A different kind of session: not an execution run that flushes a lifecycle bug,
but a **faithfulness audit** of the shipped `dynamic-workflow` (v5) skill against the stated
goal — *"a close replica of dynamic workflows as they appear in Claude Code."* Two independent
read-only lenses (both `explorer`/opus, cross-checked, no LLM in the dispatch loop): Lens A
scored the skill property-by-property against Claude Code's seven defining properties
(feasibility §1); Lens B assessed the gap between the feature's *runtime shape* and what the
skill actually instructs sybil to do. The two lenses converged with no material disagreement.

**Verdict: a faithful replica of the *thesis*, a Tier-1 PoC of the *feature*.** The skill
nails the irreducible core — plan-as-code, deterministic dispatch, all intermediate state held
in program variables, one synthesized answer returned — and that core is empirically green (to
N=12). But it diverges from or is silent on **four of the seven** defining properties.

**The seven-property scorecard:**

| Claude Code property | Rating | Evidence |
|---|---|---|
| P1 — plan in code; context sees only the final answer | **Faithful** | `print(synthesize(list(outcomes)))`; "the parallel fan-out never enters your context." |
| P2 — the *script* decides what runs next (deterministic) | **Faithful** | `asyncio.gather` over a fixed task list + semaphore; no LLM in the dispatch loop. |
| P3 — scale dozens–hundreds; caps ≤16 concurrent / 1000 total | **Partial** | `MAX_CONCURRENCY` is an editable local semaphore enforced by nobody; no 1000-total cap; validated only to N=12. Caps are convention, not guarantee. |
| P4 — quality patterns (cross-review, multi-angle) codified in code | **Divergent** | Named as use-cases, but `synthesize()` is a stub string-join; no agent reviews another in the template. |
| P5 — background + resumable; completed agents cached | **Absent** | "No background/resume." A host process can't inherit the durable loop's checkpoints — structurally unavailable, not merely unimplemented. |
| P6 — script has NO FS/shell access; only agents do | **Divergent (biggest gap)** | Inverted: the program runs *via* `sys_os_shell` in sybil's ambient sandbox, full host FS/shell, no token. The secretless egress/credential sandbox (feasibility §3.1, the stated "crux") is unbuilt. |
| P7 — invocation via `/<name>`+`args`; on-disk artifact | **Partial** | Artifact half met (real, re-launchable `.sybil/workflows/<slug>.py`); no saved `/command`, no global `args` — each run hand-edits in-file constants. |

**The single biggest fidelity gap is P6 — the absent sandbox.** Claude's "the script itself has
no direct filesystem or shell access; only the agents read/write/run" is load-bearing for the
whole security model; the shipped skill ships the exact opposite (agent-authored code with full
host reach), safe only by the accident of being local single-user. P4 (quality patterns as
prose, not code) is the runner-up: the canonical Claude example — independent agents reviewing
each other before findings report — has no analog in the template's `synthesize()` stub.

**A launch-shape divergence worth recording (Lens B).** Beyond the property list: the v1 launch
is a **blocking `sys_os_shell` call** that re-occupies the orchestrator's turn for the *entire*
run — the opposite of the feature's "backgrounded durable task" shape (feasibility §3.4 step 2;
the gap is already named in §2.5). It removes per-step *thinking* but not turn-*occupancy*. And
the headline multi-vendor advantage (fan out across Claude/Codex/Cursor/Pi — "something Claude's
single-vendor workflows cannot") is **unexpressed**: the template hard-codes `WORKER =
"explorer"` and every validated run (§7, §9, §10) is explorer-only.

**The skill is honest about all of this.** It labels itself v1, enumerates "What this v1
deliberately does NOT do" (no sandbox / no caps / no background-resume / no auth), and points to
"graduate to the first-class workflow feature" when the limits bite. The lone overclaim is the
one-liner description ("the deterministic-program analog of Claude Code's dynamic workflows"),
which a skimmer reads as stronger equivalence than the body delivers. **So the gap is not
dishonesty; it is that the stated goal ("close replica") is a higher bar than the artifact's
own modest self-claim ("Tier-1 PoC of the thesis").**

**Path to a genuine "close replica"** (none shipped today; maps to the deferred items already
in feasibility §4 and §5 recommendations): **P6** the hardened sandbox (egress allowlist +
secretless `credential_proxy`, no FS/shell) — a runner/server build and the biggest piece;
**P3** an enforced per-run cap ("the one real net-new"); **P5** runner-launched durable task +
run-graph cache for background/resume; **P4** codify cross-review / multi-angle as real template
patterns (the cheapest, skill-prose-only win); **P7** a saved `/command` + `args`. Tightening
the over-strong one-liner description is a free correctness fix and the only one sybil authors
directly — the rest are runner/server code (→ `builder` + Codex `reviewer`).

**Lesson.** "Close replica" turned out to be the wrong yardstick for what shipped — and the
skill never actually claimed it; the goal-as-stated outran the artifact's honest
self-description. The shipped skill is the *thesis* proven (plan-as-code works; state stays out
of context) on top of an unfinished server surface; the *feature's* guarantees (isolation,
caps, resumability, codified quality patterns) are designed-but-unbuilt. This is the first
session to audit the artifact against the goal rather than flush a runtime defect — and it
relocates the remaining work from "more lifecycle bugs to find" to "four named
feature-guarantee builds, P6 first."
