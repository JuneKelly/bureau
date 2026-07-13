# AGENTS.md

Guidance for coding agents working in the **bureau** repo. Sybil's own agent
config (prompt, sub-agents, skills) lives under `omnigent/agent-configs/sybil/`.

## Shell scripts

Write scripts that survive how they're actually invoked, not just the happy path:

- **`set -u`-safe env reads** — guard optional variables: `"${HOME:-}"`, never a
  bare `"$HOME"`. Under `set -u`, reading an unset variable aborts the script,
  turning an expected fallback (e.g. no `$HOME`) into a crash.
- **Symlink-safe self-location** — if a script locates its own directory to find
  a sibling file, resolve it physically with `cd -P` and account for invocation
  via a symlink. Logical `cd`/`pwd` compute the wrong directory when a parent is
  symlinked and the target path is relative.
- **No reliance on the caller's CWD** — reference files relative to the resolved
  script dir, not the current working directory.
- **Fail loud on missing tools/input** — guard external tools with `command -v`
  and exit non-zero with an actionable message; don't silently substitute a
  default. (Optional config with a documented default is the only exception.)

## Prose & docs (Markdown, text)

Before committing authored prose, scan for stray non-ASCII / homoglyphs (e.g. a
Cyrillic letter hiding inside an English word) with a **portable** check, and
actually read the output:

```sh
LC_ALL=C grep -n '[^ -~]' path/to/file.md
```

`grep -P` is **not** portable — BSD/macOS grep rejects it, so a `-P` check errors
out and verifies nothing. Legitimate typography (em dash, ellipsis, arrow) will
also match; confirm each hit is intentional.
