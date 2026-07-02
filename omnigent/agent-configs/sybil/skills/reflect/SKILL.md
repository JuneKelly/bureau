---
name: reflect
description: At the end of a long or complex session, look back over how the run actually went and surface concrete, evidence-anchored suggestions for improving sybil itself — its config, skills, roster, or routing. Use when the user types /reflect, asks sybil to "self-reflect", "reflect on this session", "do a retro", or "what could be better about how you ran this". Produces SUGGESTIONS only — it never implements them, actioning a chosen suggestion routes through the normal paths (sybil authors skill/doc prose directly; config / policy / roster changes go through fanout + cross-review).
---

# reflect — end-of-session self-improvement

Reflection looks BACK at the session that just ran — the real orchestration:
what was dispatched, to which worker and model, which waves stalled or looped,
what got cancelled or escalated, where the human had to step in, and where the
design fought the work — and turns that into concrete improvement suggestions
for sybil's own config, skills, and roster. It is the one task sybil reasons
through largely on its own, because the primary evidence is sybil's OWN
conversation, not the codebase.

It produces suggestions, never edits. Actioning any suggestion goes through the
normal paths: sybil authors a skill/doc edit directly (prose), and anything
touching `config.yaml`, guardrail policies, or the roster is a code change that
goes through `fanout` + `cross-review`. Same discipline as `cross-review`
itself — surface the issues, route them, let the human choose; don't fix in
place.

## Procedure

1. Set the scope. Default: the current session, end to end. If it's very long,
   focus on the segments with the most signal — failures, retries, loops,
   cancellations, escalations, dropped/announce-only turns, and human
   interventions — rather than narrating every turn.
2. Reconstruct what actually happened from the transcript. Build a short,
   factual timeline of the orchestration: tasks, the worker + model each ran
   on, dispatch waves, deterministic gates, cross-reviews, escalations,
   cancellations, and any moment the human took over or unblocked something.
   Use only what the session shows; do not embellish or assume.
3. Score the run against sybil's own operating rules, noting evidence for each:
   - **Delegation discipline** — did sybil write code or run a deep
     investigation itself when it should have delegated? Did it stay
     brain-only?
   - **Act-in-the-same-turn** — any turns that announced intent with no tool
     call? Any busy-polling, or timer/`sys_timer_set` misuse instead of
     inbox waits (vs. the one sanctioned bounded-watchdog use)?
   - **Routing fit** — right worker and right model per task (`explorer` vs
     `drone` for reads; `builder` vs `drone` for changes; `reviewer` always
     cross-vendor)? Any omitted/incorrect `args.model`? Any too-big-hammer
     dispatch where a cheaper tier would do?
   - **Verification** — did every implementation PR get cross-reviewed by
     `reviewer`? Any self-sign-off or skipped gate?
   - **Hygiene & safety** — isolated worktrees, bd task state kept current,
     never-merge honored, escalation at the right gates (plan gate, hard
     blocks, unavailable worker).
   - **Efficiency & cost** — redundant dispatches, unnecessary waves, work that
     could have been one task instead of three (or vice versa).
   - **Friction** — where the design fought the work: an awkward rule, a skill
     step that broke or nearly broke in the normal case, or a missing rule that
     let something slip.
4. Anchor every finding in a specific moment from the session ("at the H2
   verification, the review-worktree command would have collided without
   `--detach`"; "the H5 builder stalled on `gh` auth, which needed the human").
   No anchor → don't raise it. Never invent a quote, a line number, an event,
   or a metric that the session doesn't actually contain.
5. Verify before asserting anything about sybil's CURRENT text. Any suggestion
   that claims "the prompt says X" or "skill step N does Y" must be checked
   against the live file first: read it yourself (reading sybil's own
   config/skills/docs is allowed — it's not a codebase investigation), or, when
   a suggestion needs a deeper grounded audit across files, dispatch `explorer`
   (`purpose: "explore"`, `args.model: "claude-opus-4-8"`) and synthesize from
   its report. Do not propose a fix to a rule you have not re-read.
6. Produce the reflection as console output (no files unless the user asks),
   in three parts:
   - **What worked** — briefly, the orchestration patterns that paid off. Keep
     it honest and short; this is not padding.
   - **Friction & misses** — what fought the work or slipped through, each with
     its session anchor and a severity (high / medium / low).
   - **Suggestions** — concrete and ranked. Tag each with: WHERE it lands
     (file + section), what KIND of change it is — skill/doc prose (sybil
     authors directly) | config / policy / roster (code change via `fanout` +
     `cross-review`) | human decision — and a one-line action.
7. Do NOT implement anything from this skill. End by asking the user which
   suggestions (if any) to action, then route each chosen one through its
   proper path: author pure skill/doc prose yourself; send anything touching
   `config.yaml`, policies, or the roster to `builder`/`drone` and then
   `cross-review`. Never auto-edit config, never open a PR here, never merge.

## Notes

- Reflection is the rare task sybil drives largely solo, because the evidence
  is its own conversation. The delegation rule still bites the instant a
  suggestion needs grounding in the codebase's current state or needs
  implementing — read your own skills/docs directly, but delegate real code
  investigation to `explorer` and every code/config change to `builder`/`drone`
  - `cross-review`.
- Be critical, not self-congratulatory. The value is naming friction and misses
  precisely. A reflection that only praises the run is a failed reflection.
- Suggestions are SUGGESTIONS. Surface and route; don't fix in place — mirror
  how `cross-review` reports issues without touching the code.
- Prefer a few high-leverage suggestions over an exhaustive list. Rank by
  impact: correctness and safety first, then efficiency and cost, then
  ergonomics.
- Only claim a recurring/cross-session pattern if THIS session actually shows
  it more than once. Don't generalize a one-off into a trend without evidence.
- Persisting the reflection (e.g. a dated note or `REFLECTION.md`) is opt-in:
  write a file only if the user asks, and keep it out of tracked paths unless
  told otherwise (`.sybil/` is already gitignored).
- This skill needs no `config.yaml` entry — skills are auto-discovered from
  `skills/`. It is a standalone meta-skill, not part of the
  investigate → fanout → cross-review pipeline, so it deliberately lives
  outside that composing list.
