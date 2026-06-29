# Replicating Claude "dynamic workflows" in Omnigent — design

Status: **recommended design** (supersedes the earlier feasibility investigation
on this branch; that investigation's findings are folded in as evidence below)
Author: investigation + design spike
Question asked: *Can we replicate Claude Code's "dynamic workflows" in Omnigent,
as securely as possible?*

## Summary

**Yes — and the secure design is clearer than the first investigation suggested.**

The heart of the feature is: an **orchestrator agent decides on a complex
workflow, writes a deterministic program that implements it, and runs that program
without the agent having to "think through" each step**. The program — not an LLM
turn loop — creates sub-agent sessions, fans them out in parallel, holds every
intermediate result in its own variables, and returns only the final answer. The
sub-agents it spawns appear as children of the orchestrator's session.

The design decision that makes this both faithful *and* secure is **how the program
is confined**: it runs as a **sandboxed process whose only egress is the local
Omnigent server**, reached through Omnigent's existing hardened egress proxy — with
**no filesystem, no shell, and no token of its own**. The proxy attaches the
server credential on the way out (the "secretless" `credential_proxy` pattern, §5),
so agent-authored orchestration code never holds a credential and can reach nothing
but the session API. That confinement is a direct mirror of how Claude constrains
its own workflow script — "the script itself has no direct filesystem or shell
access; only the agents read/write/run" — and Omnigent enforces it with
infrastructure that already exists and is CVE-hardened against host-smuggling and
SSRF.

> **Correction vs. the prior turn's recommendation.** An earlier draft said the
> program must run "trusted-side" because the agent sandbox denies credentials.
> Closing the confidence gap (§5) surfaced the `credential_proxy` + `egress_rules`
> machinery, which is the *sanctioned* way to give a sandboxed process scoped,
> never-held access to one host. So the program runs **sandboxed**, not trusted-side
> — both more faithful to Claude's model and strictly more secure.

Everything else the feature needs already ships: the Python client SDK
(`omnigent_client`), parallel sub-agent fan-out/join, mixed-vendor workers,
cross-vendor adversarial review, a crash-durable agent loop, the L7 egress proxy +
secretless credential proxy, and a web-UI sub-agent tree. **Investigating the four
remaining gaps (§6) shrank the new work further: parenting children, rendering them
in the tree, and driving them are all already free** (the public JSON create takes
`parent_session_id`; child access delegates to the parent). The one piece the goal
*strictly requires* and that does **not** exist today is a **per-run cap** on
programmatic fan-out; a capability-scoped token and (for long runs) a token-refresh
hook are deferrable hardening, with a short-lived *user* token working immediately.

---

## 1. What Claude dynamic workflows are

Sources: <https://code.claude.com/docs/en/workflows>,
<https://claude.com/blog/introducing-dynamic-workflows-in-claude-code>.

A *dynamic workflow* is **a script Claude writes** and a background runtime
executes, separate from the conversation. The script orchestrates
[subagents](https://code.claude.com/docs/en/sub-agents) at scale. The defining
properties:

- **The plan lives in code, not in a context window.** The script holds the loop,
  the branching, and every intermediate result in script variables. Claude's
  context only ever sees the final answer. This is the difference from subagents /
  skills / agent teams, where an LLM is the orchestrator and decides turn-by-turn
  what to spawn.
- **Scale:** dozens to hundreds of agents per run. Hard caps: **≤16 concurrent
  agents**, **1,000 agents total per run**.
- **Quality patterns codified in code:** e.g. adversarial cross-review (independent
  agents review each other before findings are reported), multi-angle drafting.
- **Background + resumable** within the same session (completed agents return
  cached results; the rest run live).
- **The script has no direct filesystem or shell access** — only the agents
  read/write/run. Agents run in `acceptEdits` and inherit the user's allowlist.
  *(This constraint is load-bearing for our security model — see §3.2.)*
- **Invocation:** a keyword/effort trigger, or a saved command (`/<name>`) that
  reads its input from a global `args`. The script is a real artifact on disk —
  readable, diffable, editable, re-launchable.

The docs' comparison table is the cleanest framing of where this sits:

| | Subagents | Skills | Agent teams | Workflows |
|---|---|---|---|---|
| What it is | A worker Claude spawns | Instructions Claude follows | A lead agent supervising peers | **A script the runtime executes** |
| Who decides what runs next | Claude, turn by turn | Claude | The lead agent, turn by turn | **The script** |
| Where intermediate results live | Context window | Context window | A shared task list | **Script variables** |
| Scale | A few per turn | Same | A handful | **Dozens–hundreds per run** |

Omnigent's multi-agent story today maps onto the **"agent teams"** column: an LLM
orchestrator decides turn-by-turn what to spawn, and state lives in its context.
The target is the **Workflows** column.

---

## 2. The substrate Omnigent already has

Almost everything a workflow runtime needs is in the tree; only "plan-as-code
outside an LLM context" is missing as a *feature*.

- **A typed Python client SDK — `omnigent_client`.** Omnigent is a server with a
  documented REST + SSE API (`openapi.json`) and a typed client SDK
  (`sdks/python-client/omnigent_client`). The SDK does session create, multi-turn
  `send`/`query`, SSE streaming as raw events or semantic blocks, client-side tool
  handling, `fork`, model override, and a `child_sessions` tree reader described as
  "the queryable rollup an SDK driver needs" (`_sessions.py:684`, `fork` at `:887`).
  *This is the API the workflow program calls.*
- **Parallel sub-agent fan-out / join.** `sys_session_send`
  (`omnigent/tools/builtins/spawn.py`) launches a sub-agent as an independent task
  and returns a non-blocking handle; results auto-deliver over the
  `async_work_complete` topic and are collected via the inbox. Fan-out and join
  already exist — they are just LLM-driven today.
- **Programmatic, parented session creation (internally).** The internal
  `sys_session_create` accepts `parent_conversation_id` and can create an **idle,
  create-only** child (`spawn.py:540`, `:897`) — the exact "provision but don't
  drive" split the design relies on.
- **Mixed harness/model per worker** (`docs/AGENT_YAML_SPEC.md`); Polly already
  routes per dispatch via `args.model`.
- **Cross-vendor adversarial review is a worked example.** Polly
  (`examples/polly/config.yaml`) implements "implementer's diff reviewed by a
  *different vendor*" — but as prompt instructions, not code.
- **Fan-out caps as policy.** Polly's `spawn_bounds`
  (`max_dispatches_per_turn: 5`) is the natural hook for the 16/1000 caps.
- **Crash-durable agent loop** (`omnigent/runtime/workflow.py`, "all durably
  checkpointed for crash recovery") — the foundation for background + resumable.
- **Sub-agent tree + web UI for free.** The tree is *derived* from two stored
  fields (`kind == "sub_agent"`, `parent_conversation_id == <orchestrator id>`);
  `GET /v1/sessions/{id}/child_sessions` is a query over them
  (`sqlalchemy_store.py:820`). Any session carrying the orchestrator's id as parent
  appears in the Subagents panel with no extra wiring.

The one thing absent as a feature: a way to express the orchestration as
**deterministic code that runs outside an LLM context**. Today every orchestrator
is itself an LLM agent. That gap is what §3 fills.

---

## 3. Recommended architecture

### 3.1 How the program is confined — the crux

Run the workflow program as a **sandboxed process whose only reachable destination
is the local Omnigent server**, with no filesystem, no shell, and no credential of
its own. This is the sanctioned shape for "give a confined process scoped access to
exactly one host," and Omnigent already ships every piece of it (§5):

- **Hard network isolation + an L7 egress proxy.** `linux_bwrap` unshares the
  network namespace (`--unshare-net`) and `darwin_seatbelt` emits `(deny network*)`,
  so the **only** egress path is a MITM proxy on a loopback socket. `egress_rules`
  (a `METHODS host/path` DSL, host grammar CVE-hardened against the smuggling class
  Anthropic's own sandbox-runtime fix called out) allowlists that proxy to the
  Omnigent server and nothing else.
- **Secretless credentials.** The program holds **nothing credential-shaped**. It
  makes plain requests to the server with no `Authorization` header; the egress
  proxy attaches `Authorization: bearer <real>` on the way out, bound to the server
  host, and rejects the same credential replayed to any other host with HTTP 403
  (the cross-host leak guard). The real secret is resolved in the *parent* and never
  enters the sandbox (`credential_proxy`, `inner/credential_proxy.py`,
  `inner/egress/proxy.py`).
- **No FS, no shell.** The sandbox is deny-by-default on the filesystem; the program
  is pure Python calling the SDK and needs neither shell nor host files. This is the
  exact constraint Claude imposes on its workflow script.

This supersedes the prior turn's "run it trusted-side" framing. The agent
`sys_os_shell` wall (§5) is real and stays; `credential_proxy` is the *sanctioned
hole through it* — narrow, host-bound, secretless — so we don't need to put the
program on the trusted side or hand it a token at all.

### 3.2 The security model (mirrors Claude; arguably tighter)

Layering the above, the blast radius of a malicious or buggy workflow program is
bounded by construction:

1. **Reaches only the server.** Hard namespace isolation + `egress_rules` mean no
   exfiltration path and no SSRF — with one caveat that is itself a security control:
   the proxy blocks **private/loopback destinations by default**
   (`egress_allow_private_destinations=False`, plus a cloud-metadata trap network
   list). Since the local server is on loopback, the orchestration profile must
   carve out *exactly* the server address — a deliberate, auditable exception, not a
   blanket private-network allow (§4, §8).
2. **Holds no credential.** Secretless swap-on-access (§3.1) means there is no token
   in the sandbox to steal, log, or leak.
3. **Two-tier authorization on what the (proxy-attached) token can do:**
   - **Interim (available now):** a **short-lived user-session token**
     (`_mint_loopback_cli_token`-style, with TTL) resolved via a `credential_proxy`
     `command` source. Capability = "whatever this user can do via the API," but
     only through the server, only for the token's short life, and only via code
     that cannot exfiltrate it. Strong enough for early use; **not** the final story.
   - **Target (the one real new primitive):** a **capability-scoped token** — *create
     and drive child sessions owned by this user, parented under this one session,
     within the run caps* — enforced server-side on the parent-aware create endpoint
     (§3.3). This bounds the blast radius to the workflow itself.
4. **Per-spawn governance — partly free, one real gap.** Per-session *access* is
   enforced (the create authorizes the parent at `LEVEL_READ`, §3.3) and per-session
   policy/cost still apply once a child runs. **But the existing fan-out caps do
   *not* apply to programmatic creates:** `spawn_bounds` gates the orchestrator's
   *tool calls* (`sys_session_send`/`sys_session_create`), and the public create
   endpoint (`create_session`) runs no such policy. So a runaway program could spawn
   unbounded children. A **per-run cap is therefore genuinely net-new** (§4) — either
   a counter enforced at create, or a quota carried by the scoped token.

> Honest residual risks: (a) we are still *executing agent-authored code* — same as
> Claude; the isolation that bounds it is the OS sandbox + egress proxy, **not**
> language sandboxing (RestrictedPython is fragile; do not rely on it). (b) Until the
> capability-scoped token exists, the interim user token is over-privileged *in
> principle* (full user API), though never held by the program and never reachable
> off-host. (c) The loopback carve-out (point 1) must be scoped to the exact server
> origin or it widens to a private-network SSRF hole. (d) Without the net-new per-run
> cap (point 4), nothing bounds programmatic fan-out — this is the one place the
> "behaves well with orchestrator sessions" goal needs new code, not just config.

### 3.3 Parenting — already shipped, not net-new (corrected)

**This is the biggest correction from closing the gaps: parenting already works
through the public API today.** An earlier draft (and the prior §6) said "the public
create API has no parent parameter — only the internal `sys_session_create` does."
That conflated two create modes on `POST /v1/sessions`:

- the **bundle / multipart** mode (the `omnigent_client` SDK `create(bundle=…)`
  wrapper) — which indeed takes no parent; and
- the **JSON mode** binding an existing `agent_id` (`_create_session_from_existing_agent`),
  which **does** accept `parent_session_id` (`SessionCreateRequest.parent_session_id`,
  `schemas.py:1230`).

The JSON path authorizes the parent at `LEVEL_READ` (`sessions.py:11800`) — which the
orchestrator's owner trivially has — then creates a `kind="sub_agent"` row with
`parent_conversation_id` set and the runner inherited from the parent
(`sessions.py:11951-11953`). Because the child-listing query is *only*
`kind=="sub_agent"` + `parent_conversation_id` (`sqlalchemy_store.py:839`) and
`root_conversation_id` auto-derives from the parent at create, **the spawned session
appears in the Subagents panel with zero further work.**

So §7 "Option 2 (parent-aware create)" is **not a build item** — it exists. The only
residual is ergonomic: the Python SDK *wrapper* doesn't surface the kwarg, so the
program either hits the REST endpoint directly or we add one parameter to the
wrapper. The one combination *not* covered is "upload a brand-new agent bundle **and**
parent it" (bundle mode takes no parent); fanning out to **existing registered
agents by id** — the common workflow case — is fully covered today. (Net-new bundles
per child, if ever needed, still go through the internal `sys_session_create`.)

The capability-scoped token (§3.2 target tier) later narrows *which* parent a given
token may create under (`parent == token.scope.parent`), but that is hardening on top
of a working mechanism, not a prerequisite.

### 3.4 End-to-end flow

1. **Decide + author.** The orchestrator (LLM) decides a workflow is warranted,
   writes a deterministic `workflow.py` against a thin `omnigent_workflow` helper
   (over `omnigent_client`), and triggers it. *This is the only LLM judgment in the
   loop — what to decompose and, later, whether the result is good.*
2. **Launch (sandboxed).** The runner starts `workflow.py` as a session-scoped
   durable task under the §3.1 orchestration profile: network hard-isolated, egress
   allowlisted to the server, FS/shell denied, and a `credential_proxy` entry that
   attaches the (interim user / target scoped) token to its server requests — which
   the program itself never holds.
3. **Run (deterministic).** The program creates parented child sessions, fans out
   with `asyncio.gather`, holds all intermediate state in its own variables,
   applies branching / cross-vendor review / synthesis in plain code.
4. **Children show up live.** They are ordinary parented sub-agents, so the web UI
   Subagents panel and session tree render the run with no new transport.
5. **Return one answer.** Only the final value is posted back to the orchestrator's
   conversation; the intermediate fan-out never enters any LLM context.
6. **Save / reuse.** The `workflow.py` artifact saved to `.omnigent/workflows/<name>`
   becomes a re-runnable `/command` reading its input from `args` — directly
   analogous to Claude's save flow and compatible with bundle distribution.

**Distinct Omnigent advantage:** because Omnigent is multi-harness, one run can fan
out across *Claude Code, Codex, Cursor, Pi, …* — something Claude's single-vendor
workflows cannot. The cross-vendor review Polly does in prompts becomes a
first-class, codified workflow step.

---

## 4. What's new vs. reused

Closing the four investigation gaps (§6) shrank this further: parenting, tree
rendering, and child-driving are all **already free**. The remaining build is **one
real primitive (per-run caps) + glue**, with the scoped token as security hardening
on top.

| Item | Build size | Notes |
|---|---|---|
| **Per-run caps** | the one real net-new | The public create endpoint runs **no** spawn policy (`spawn_bounds` only gates the orchestrator's *tool calls*, §6/Q3). Without a per-run counter, a programmatic fan-out is unbounded. Enforce at create, or as a quota on the scoped token. *This is the only piece the "behaves well" goal strictly requires.* |
| **Capability-scoped token** | hardening (defer) | Server-issued token scoped to `{user, parent_session_id, caps}`. *Interim:* a short-lived **user** token via `_mint_loopback_cli_token` works now with **zero new server work** (access to children is already covered by parent delegation, §6/Q2), so this lands after v1. |
| ~~Parent-aware create~~ | **freebie** | **Already exists** — `POST /v1/sessions` JSON mode takes `parent_session_id`, authorizes the parent at `LEVEL_READ`, creates the `kind="sub_agent"` row (§3.3 / §6 Q3). Optional: surface the kwarg on the SDK wrapper (one parameter). |
| Orchestration sandbox profile | glue (config) | An `OSEnvSandboxSpec` with `allow_network=False`, `egress_rules=["* <server-origin>/**"]` (the loopback carve-out, §3.2/§8), a `credential_proxy` `https_bearer` entry sourced by `command`, FS/shell denied. **No new sandbox code** — all existing fields. |
| `omnigent_workflow` wrapper | glue | Thin `spawn` / `gather` / `review` / `synthesize` over `omnigent_client`. |
| `/workflow` trigger + launch-as-task | glue | Reuse the durable-task pattern from `runtime/workflow.py`. |
| Long-run token refresh | small, only if needed | The `credential_proxy` `command` source resolves **once at launch** (§6 Q4); a multi-hour resumable run needs a token TTL ≥ run length, or a refresh hook. Not needed for short runs. |

**Reuse — already in the tree:** `omnigent_client` SDK; fan-out/join; mixed-vendor
workers; cross-vendor review (Polly); **parented create via the public JSON API with
parent-delegated access (§6 Q1–Q3) — the tree, child-driving, and nesting are all
free**; the bwrap/seatbelt sandbox; **the L7 egress proxy (`egress_rules`) +
secretless `credential_proxy` with cross-host leak guard and SSRF defense** (§5.2);
short-lived user-token minting; the durable loop; per-session policy/cost; the
web-UI sub-agent tree.

---

## 5. Evidence: the credential boundary and the egress proxy

This section records the investigation that drove §3.1/§3.2, in two halves: first
*why a token can't simply be thrown into an agent payload's environment*, then *the
sanctioned mechanism that solves it cleanly* — which is the finding that reshaped
the design.

### 5.1 A token is withheld from agent payloads — deliberately

1. **Deny-by-default env for `sys_os_shell`.** `build_helper_env`
   (`inner/os_env.py:159`) passes through only `_DEFAULT_ENV_PASSTHROUGH`
   (`PATH`, `HOME`, locale, `TERM`, the `OMNIGENT` session *marker*) — no
   credentials. The rationale is stated in-code: otherwise "the helper would just
   call `sys_os_shell('env')` to enumerate every secret and `curl` it out."
2. **The runner auth secret is *always* stripped** — both branches, even
   `sandbox.type: none`: `strip_runner_auth_secrets` removes
   `RUNNER_AUTH_SECRET_ENV_VARS = {RUNNER_TUNNEL_BINDING_TOKEN_ENV_VAR}`
   (`runner/identity.py:58`). Comment: "the helper runs the agent's tool payload,
   which must never see the tunnel binding token."
3. **The filesystem is deny-by-default.** The user's OIDC bearer lives on disk in
   `~/.omnigent/auth_tokens.json`. On `linux_bwrap` the sandbox is a mount namespace
   that exposes only bound paths (cwd / `read_paths` / explicit mounts), with a
   dotfile masker over those roots (`bwrap_sandbox.py`, `_cwd_scan.py`); on
   `darwin_seatbelt` the profile denies sensitive home subpaths. **Correction to an
   earlier draft:** I previously asserted the sandbox "tmpfs-masks `~/.omnigent` by
   the same rule as `~/.aws`/`~/.ssh`." The masker I cited is *cwd/read-path*-scoped,
   and the macOS sensitive-subpath denylist I found names only `~/Library`
   (`_SENSITIVE_HOME_SUBPATHS_DARWIN`). The accurate statement is weaker: the agent
   payload sandbox is **deny-by-default on FS, so `~/.omnigent` is not exposed unless
   something binds it** — but I did not trace an *explicit* `~/.omnigent` mask on both
   backends. This is moot under the chosen design anyway (§5.2): the workflow program
   reads no token from disk.

### 5.2 The decisive enabler: hard egress isolation + a secretless credential proxy

The first investigation guessed this would need "a small plumbing task to thread a
token." It doesn't — Omnigent already ships exactly the right primitive, and it is
*more* secure than threading a token:

- **An L7 egress proxy behind hard network isolation** (`inner/egress/`,
  `inner/sandbox.py`, `inner/datamodel.py`). With `egress_rules` set, the backend
  hard-isolates the network (`linux_bwrap` `--unshare-net`; `darwin_seatbelt`
  `(deny network*)`) so a MITM proxy on a loopback socket is the **only** egress
  path. Rules are a `METHODS host/path` DSL (`inner/egress/rules.py`) with a
  DNS-safe host grammar whose comment explicitly cites "Anthropic's Claude Code
  sandbox-runtime CVE-class fix" for host-smuggling (NUL/`%2e`/CRLF) defenses.
- **Secretless credential injection** (`CredentialProxyEntry`, `datamodel.py:400`;
  `inner/egress/proxy.py`). The sandbox holds *nothing* credential-shaped. A request
  to the bound `host` with no `Authorization` header gets `Authorization: <scheme>
  <real>` attached by the proxy on the way out; the real secret is resolved in the
  *parent* (`source` may be `env` / `path` / **`command`** — i.e. a dynamically
  minted token), and a placeholder replayed to any other host is rejected **403**
  (cross-host leak guard). These are parsed/validated spec fields
  (`spec/parser.py`, `spec/validator.py`), not bespoke wiring.
- **SSRF defense built in.** `egress_allow_private_destinations` defaults `False`
  and a cloud-metadata trap network list is enforced — which is why the local
  (loopback) server needs an explicit, narrow carve-out in the orchestration profile
  (§3.2 point 1, §8).
- **Still available if ever needed — a trusted-side token minter and a threading
  precedent:** `_make_auth_token_factory()` (`runner/_entry.py:271`) mints fresh
  server bearers, and the policy callback already stamps
  `{server_url, session_id, Bearer token}` into a child process
  (`runner/app.py:1135-1145`). The design does **not** rely on these — the secretless
  proxy is strictly better — but they confirm the parent can mint a server token for
  the `command` source.

**Conclusion that drove the design:** don't thread a token into agent-authored code
at all. Run the program **sandboxed with hard egress isolation**, allowlist the
proxy to the server, and let the **secretless `credential_proxy`** attach a token
the program never sees — interim a short-lived user token, target a
capability-scoped one (§3.2). This is faithful to Claude's "no FS/shell" script and,
because the program holds no credential and can reach only one host, **more** secure.

---

## 6. Parenting & access — four gaps investigated (mostly freebies)

This section records the resolution of the four lines of investigation. Three came
back as freebies; one (caps) is the genuine net-new piece. All are static reads on
this branch.

**Q1 — Tree rendering needs only `(kind, parent)`.** The child-listing query is
*purely* `kind=="sub_agent"` AND `parent_conversation_id IN (...)`
(`list_child_conversation_ids_by_parent`, `sqlalchemy_store.py:839`). The
`root_conversation_id` I worried might also be required (the "spawn-tree root") is
**auto-derived from the parent at create** (`create_conversation` inherits
`parent_row.root_conversation_id`), not a caller-set field. `sub_agent_name`/`title`
affect only the display label. **So a parented session renders in the Subagents panel
for free.**

**Q2 — Driving a child is parent-delegated (best case).** `check_session_access`
(`permissions.py:51`) delegates a sub-agent's access check **entirely to its parent**,
recursively to the root. So the orchestrator's owner automatically holds owner-level
access to every descendant; a program acting with the user token can
`post_event`/`stream`/read `items` on any child it parents with **no per-child
grant**. Corollary: a token scoped to "parent session S" authorizes the whole subtree
— the scope model and the access model coincide.

**Q3 — Parent-aware create already exists (the "public create has no parent"
claim was wrong).** `POST /v1/sessions` has two modes; the earlier draft only saw the
bundle one:
- **Bundle/multipart** (`omnigent_client` `create(bundle=…)`, `_sessions.py:338`) —
  no parent param. *This is what the earlier §6 cited.*
- **JSON, bind existing `agent_id`** (`_create_session_from_existing_agent`) — **does**
  take `parent_session_id` (`SessionCreateRequest.parent_session_id`,
  `schemas.py:1230`), authorizes the parent at `LEVEL_READ` (`sessions.py:11800`),
  and creates the `kind="sub_agent"` row with runner inherited
  (`sessions.py:11951-11953`). Exposed in the public OpenAPI.

So parenting works **today, zero server changes**, for fan-out to existing agent ids.
Uncovered combo: *new-bundle-per-child + parent* (bundle mode takes no parent) —
handled by the internal `sys_session_create` if ever needed.

**Q4 — The `credential_proxy` `command` source resolves once.**
`prepare_credential_proxy_runtime` resolves each source at launch and hands the proxy
a fixed secret (`credential_proxy.py:132`); no per-request refresh. Fine for short
runs; a long resumable run needs a token TTL ≥ run length or a refresh hook (§4).

**The one real gap — caps.** The public create runs **no** `spawn_bounds`/per-run
policy (that policy gates the orchestrator's *tool calls*, not the create endpoint),
so programmatic fan-out is unbounded without a new per-run cap (§3.2 point 4, §4).

*Still true and still relevant:* `parent_conversation_id` is **immutable after
create** (`update_conversation`, `sqlalchemy_store.py:1780`, has no parent field), so
*adopting* an existing top-level session by id remains impossible without a core
change — but the design never needs adoption, since children are created already
parented.

---

## 7. Phasing

1. **PoC — prove the loop, zero security work (hours–days).** A standalone Python
   script using `omnigent_client` against a local server: create N **parented**
   children via the JSON create (`parent_session_id`, §6 Q3), `asyncio.gather`
   fan-out, drive each child (parent-delegated access is free, §6 Q2), cross-vendor
   review in code, post one synthesized answer back. Because parenting/tree/driving
   are freebies, **the PoC can already nest under the orchestrator** — no need to
   start flat. Uses a full bearer; no sandbox yet.
2. **Secure interim — the §3 sandbox, user token (days).** Run the script under the
   orchestration sandbox profile (hard egress isolation + `egress_rules` to the
   server + secretless `credential_proxy` sourcing a short-lived **user** token).
   Add the **per-run cap** (the one governance piece, §4) so fan-out is bounded. This
   delivers the full faithful behavior using **only existing infrastructure plus one
   cap** — the sole un-hardened bit is that the proxy-attached token is user-scoped.
3. **Secure target — capability-scoped token + durability.** Add server-side issuance
   + enforcement of the `{user, parent_session_id, caps}` scope (folds the cap into
   the token), durable background execution + resumability, and (if runs go long) the
   token-refresh hook (§6 Q4). These are the only genuinely net-new server pieces.

---

## 8. Risks / open questions

- **The loopback egress carve-out.** The SSRF defense blocks private/loopback
  destinations by default; the local server is on loopback, so the orchestration
  profile must allow *exactly* the server origin. Scoped too widely (e.g. a blanket
  `egress_allow_private_destinations=True`) this becomes a private-network SSRF hole.
  Must be the narrowest possible host/port rule and audited.
- **Executing agent-authored code.** Bounded by the OS sandbox (net/FS/shell) + the
  secretless, host-bound credential proxy, not by language sandboxing. Same risk
  class as Claude's workflows.
- **Interim token is user-scoped.** Until the capability-scoped token exists, the
  proxy attaches a full **user** token (never held by the program, never reachable
  off-host, short-lived). Acceptable for the §7-step-2 interim; the §7-step-3 scope
  is what closes it.
- **Cost blow-up.** Hundreds of agents is real spend; reuse `cost_budget` and
  surface per-agent usage.
- **Resumability semantics.** "Cached completed agents" needs a run-graph-keyed
  store; the durable checkpointed loop is the foundation but not the whole thing.
  *Note:* a script running as a host process does **not** automatically inherit the
  loop's checkpoints — running it as a session-scoped durable task (§3.4 step 2) is
  what makes background + resume real.
- **Concurrency on one host.** 16 concurrent harness subprocesses is heavy;
  Omnigent's managed-host / cloud-sandbox story could distribute agents across
  sandboxes and *exceed* Claude's local cap.
- **Per-run cap is mandatory, not optional.** Resolved from "nice-to-have" to "the
  one required new piece": without it, nothing bounds programmatic fan-out (§6, Q3).
- **To verify in the PoC** (the items *not* settled by static reads):
  (a) the secretless `credential_proxy` (`command` source → MITM attach) reaching the
  **loopback** server end to end, including the private-destination carve-out;
  (b) `_mint_loopback_cli_token` (or equivalent) usable as the `command` source for
  the interim user token. *Resolved by reading and no longer open:* owner-token
  drive of a same-owner child is permitted via **parent delegation**
  (`permissions.py:51`, §6 Q2) — not merely ownership-gated; it's strictly stronger.

---

## 9. What we discarded, and why nothing essential is lost

The earlier investigation explored several shapes. The recommended design absorbs
the good ones and drops two:

- **Approach B (script over the SDK)** — *kept as the foundation.* §3 is Approach B
  with the two vague parts (where it runs, how it authenticates) pinned down.
- **Parent-aware create (old §7 "Option 2")** — *found to already exist* (§3.3 / §6
  Q3); downgraded from a build item to a freebie (optional SDK-wrapper sugar).
- **Flat / top-level sessions (old §7 "Option 3")** — *no longer needed even for the
  PoC*, since parented create is free; retained only as a fallback if parenting is
  ever undesirable.
- **Broker pattern (old §7 "Option 1") — discarded.** It had the orchestrator LLM
  mint each child on the program's behalf, putting a nondeterministic LLM turn on
  the program's hot path — the exact latency/nondeterminism dynamic workflows exist
  to remove. The scoped token (§3.2) lets the program tie its own shoes, so the
  broker is unnecessary. Nothing is lost: it was only ever defensible as a
  zero-core-change interim.
- **Re-parenting an existing session by id — discarded as infeasible.**
  `parent_conversation_id` is immutable (§6); adoption would need a core change we
  don't need, since the program creates children already parented.
- **Approach A (prompt-only Polly fork) — demoted to a fallback demo.** It keeps
  state in the LLM context, so it does not scale to hundreds of agents and is not a
  faithful replica. Useful only as a no-code-change behavioral demo.

---

## 10. Confidence

This design rests on a **static** read of code on this branch; **nothing was
executed**. That is the main caveat.

**High confidence (read directly):**
- The SDK exposes session create, `send`/`query`, SSE `stream`, `child_sessions`
  tree, `fork`, model override (`omnigent_client/_sessions.py`).
- A deterministic program can drive many sessions in parallel and hold all state in
  its own variables — the defining property. *The core thesis is the
  high-confidence part.*
- The credential boundary is real and deliberate (§5.1): agent payloads are denied
  server tokens by env deny-listing and an always-stripped runner secret.
- **The egress + secretless-credential infrastructure exists and is hardened
  (§5.2).** Hard network isolation, an L7 `egress_rules` allowlist with CVE-conscious
  host-grammar, a secretless `credential_proxy` (`env`/`path`/`command` sources,
  cross-host 403 guard), and an SSRF/private-destination default-deny — all
  parsed/validated spec fields, read directly. *This is the part that moved the
  secure-shape confidence up the most; in the prior turn I had it as an unverified
  ~50% guess and was leaning on a weaker "run trusted-side" framing.*
- **Parenting, tree rendering, and child-driving are all free (§6, read directly).**
  The child query is only `(kind, parent_conversation_id)` (`sqlalchemy_store.py:839`);
  `root_conversation_id` auto-derives; the public JSON create takes `parent_session_id`
  and authorizes the parent at `LEVEL_READ` (`sessions.py:11800`,
  `schemas.py:1230`); and access to a child delegates to its parent
  (`permissions.py:51`). The field is immutable post-create, so *adoption* is the only
  thing that would need a core change — and the design never needs it.

**Corrected from prior drafts:**
- "The public create API has no parent parameter" was **wrong** — it cited the bundle
  SDK wrapper; the JSON create route accepts `parent_session_id` today (§3.3/§6 Q3).
  Parenting moved from "small build" to **freebie**.
- The `~/.omnigent` masking claim was overstated → deny-by-default FS, backend-
  specific, not an explicit dotdir mask I traced (§5.1).
- "Run trusted-side" superseded by "run sandboxed with secretless egress" (§3.1).

**Medium / lower confidence (needs the PoC / is net-new):**
- The secretless `credential_proxy` reaching the **loopback** server with the
  private-destination carve-out, wired end to end (design clear; not executed).
- **Per-run caps** — the one piece the goal strictly requires and which does **not**
  exist on the create path today (§6, Q3).
- **Capability-scoped token** — short-lived *user* tokens exist
  (`_mint_loopback_cli_token`) but `{parent, caps}` scoping does not; it's hardening
  on top of a working interim, deferrable past v1.
- Long-run token refresh (the `command` source is one-shot, §6 Q4) — only if runs go
  long.

**Calibrated estimate:** ~90% the core thesis holds (deterministic program +
existing SDK ⇒ parallel agents with state outside the LLM context, no new runtime);
**~88%** that the design lands close to §3 — up from ~85% last turn. Closing the four
gaps *raised* confidence and *shrank* scope: three were freebies (the feature is much
closer to "usage pattern over shipping infrastructure" than even the optimistic
framing), and the residual is now concentrated almost entirely in **one required new
piece (per-run caps)** plus two deferrable hardening items (scoped token, token
refresh) and one config item (loopback carve-out). A small executed PoC — which can
now nest under the orchestrator from day one — remains the recommended next step.

### Sources

- Orchestrate subagents at scale with dynamic workflows — <https://code.claude.com/docs/en/workflows>
- Introducing dynamic workflows in Claude Code — <https://claude.com/blog/introducing-dynamic-workflows-in-claude-code>
- A harness for every task: dynamic workflows in Claude Code — <https://claude.com/blog/a-harness-for-every-task-dynamic-workflows-in-claude-code>
- Omnigent in-tree references: `openapi.json`; `sdks/python-client/omnigent_client/` (`_sessions.py`); `omnigent/tools/builtins/spawn.py`; `omnigent/runtime/workflow.py`; `omnigent/inner/os_env.py`; `omnigent/runner/identity.py`; `omnigent/runner/_entry.py`; `omnigent/runner/app.py`; `omnigent/stores/conversation_store/sqlalchemy_store.py`; `examples/polly/config.yaml`; `docs/AGENT_YAML_SPEC.md`
- Sandbox / egress / credential machinery (the §5.2 keystone): `omnigent/inner/sandbox.py`; `omnigent/inner/datamodel.py` (`CredentialProxyEntry`, `egress_rules`, `egress_allow_private_destinations`); `omnigent/inner/egress/` (`proxy.py`, `rules.py`, `controller.py`); `omnigent/inner/credential_proxy.py` (`prepare_credential_proxy_runtime`, one-shot `_resolve_secret`); `omnigent/inner/bwrap_sandbox.py`; `omnigent/inner/seatbelt_sandbox.py`; `omnigent/inner/_cwd_scan.py`; `omnigent/spec/parser.py`; `omnigent/spec/validator.py`; `omnigent/server/accounts_bootstrap.py` (`_mint_loopback_cli_token`)
- Parenting / access (the §6 freebies): `omnigent/server/routes/sessions.py` (`create_session`, `_create_session_from_existing_agent`, parent authorization at `:11800`, parented create at `:11951`); `omnigent/server/schemas.py` (`SessionCreateRequest.parent_session_id`); `omnigent/server/permissions.py` (`check_session_access` sub-agent delegation); `omnigent/stores/conversation_store/sqlalchemy_store.py` (`list_child_conversation_ids_by_parent`, `create_conversation` root derivation); `openapi.json` (`parent_session_id` in the create request)
