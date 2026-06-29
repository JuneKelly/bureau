# Dynamic workflows in Omnigent — lessons learned from a live run

Status: **empirical findings** from end-to-end executions of the
plan-as-code fan-out described in `doc/dynamic-workflows-feasibility.md`.
Companion to that doc, not a replacement.

> **Two execution sessions are recorded here.** Session 1 (below, §1–§6) was a
> 5-task fan-out that flushed the *delivery/timing/wire* pack and produced the
> **v2** skill. Session 2 (§7) re-ran the fan-out **at N=12**, flushed the next
> pack — a concurrency-timing **`idle`-overload race** that a one-task canary
> cannot see — and produced the **v3** started-gate fix, now confirmed green
> (12/12). Read §7 for the current state; §1–§6 are the still-valid Session-1
> record.

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

- **Tier 1 — local throwaway fan-out (the shipped v3 skill): VIABLE, verified.** The
  mechanism (parented create → seed-at-create → parallel poll → capture → teardown) works,
  and after the v3 started-gate it works **correctly under concurrency at N=12**, not just
  at the N=1 canary that gave false confidence (§2.8, §7). The honest caveats are scope, not
  soundness: validated to N=12 (not yet the ~16 ceiling), `explorer`-only, local
  single-user, no caps enforcement, run tied to one `sys_os_shell` call (no
  background/resume). For wide read-only fan-outs on a local box, it is usable today.
- **Tier 2 — persistent nested children, robust locally: ONE real fix away.** The blocker is
  wart §2.1 / recommendation 1: REST-created parented children get no parent work-entry, so
  they can't deliver completion and the runner retry-storms. Today's workaround is mandatory
  teardown (which forfeits persistence). Registering a work-entry on REST create — or marking
  such children "externally tracked, no parent delivery" — would let children **nest *and*
  persist *and* deliver**, dropping both the teardown and the started-gate-as-only-signal.
  This is a genuine build item, not a skill tweak.
- **Tier 3 — secure / multi-user / at-scale: DEFERRABLE, designed but unexercised.** The
  hardened sandbox (credential-proxy + egress allowlist, capability-scoped token) from
  feasibility §3.1 is design-only; the §1.5 401-bail proves Tier 1 won't run multi-user as-is.
  Right target for any shared deployment, not needed for the local single-user use case the
  skill serves.

**Bottom line.** The meta-lesson holds end to end: *the static read was flawless on
structure, blind on lifecycle, and lifecycle surprises travel in packs.* Session 1 flushed
the delivery/timing/wire pack; Session 2's N=12 run flushed the concurrency pack (the
`idle`-race) **exactly as the "validate at N≥3" instinct predicted**. Tier 1 has now
survived the probe that was designed to break it. The single highest-leverage next build is
Tier-2's work-entry fix; the next *probe* is a push toward the concurrency ceiling.
