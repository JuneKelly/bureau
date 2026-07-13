#!/usr/bin/env bash
#
# resolve-config.sh — sybil `load-config` resolver (spec 001 §5-6, §9-10).
#
# Discovers the global and project config files, deep-merges them over the
# baked-in defaults (defaults <- global <- project, project wins per key), and
# emits the fully resolved config as a single JSON document on STDOUT. Human
# advisories go to STDERR. Exit 0 on success (including no-config-found);
# non-zero only on a malformed config the user must fix.
#
# The merge / JSON logic runs in python3 (portable deep-merge; decided over jq).
# python3 is a hard dependency — if it is missing we fail loudly rather than
# silently skipping the merge.
#
# Discovery can be redirected for testing via SYBIL_GLOBAL_CONFIG /
# SYBIL_PROJECT_CONFIG, but the real runtime discovery paths (§5.1) are the
# default behavior.

set -euo pipefail

# --- Dependency check (§6.2, §10) -------------------------------------------
if ! command -v python3 >/dev/null 2>&1; then
  echo "resolve-config: python3 not found on PATH. The config resolver requires python3 for deterministic deep-merge (spec 001 §6.2). Install python3 and retry — merging is not silently skipped." >&2
  exit 2
fi

# --- Discovery (§5.1) -------------------------------------------------------
# Global: ~/.config/omnigent-sybil/config.json (SYBIL_GLOBAL_CONFIG overrides).
GLOBAL_CONFIG="${SYBIL_GLOBAL_CONFIG:-${HOME}/.config/omnigent-sybil/config.json}"

# Project: <repo_root>/.sybil-config.json, repo root via git; tolerate not
# being in a git repo (SYBIL_PROJECT_CONFIG overrides).
if [ -n "${SYBIL_PROJECT_CONFIG:-}" ]; then
  PROJECT_CONFIG="${SYBIL_PROJECT_CONFIG}"
elif repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  PROJECT_CONFIG="${repo_root}/.sybil-config.json"
else
  PROJECT_CONFIG=""
fi

# --- Merge / validate / emit (python3) --------------------------------------
python3 - "$GLOBAL_CONFIG" "$PROJECT_CONFIG" <<'PYEOF'
import json
import os
import sys

GLOBAL_PATH = sys.argv[1]
PROJECT_PATH = sys.argv[2]  # "" means no project-config location

# Baked-in defaults (§5.2). Dash-format model IDs. reviewer=null => omit model.
DEFAULTS = {
    "version": 1,
    "agents": {
        "explorer": {"model": "claude-opus-4-8"},
        "builder":  {"model": "claude-opus-4-8"},
        "drone":    {"model": "claude-sonnet-4-6"},
        "reviewer": {"model": None},
    },
}
KNOWN_AGENTS = set(DEFAULTS["agents"].keys())
KNOWN_TOP_KEYS = {"version", "agents"}
IMPLEMENTERS = ["explorer", "builder", "drone"]


def fail(msg):
    """Loud, non-zero exit for malformed config the user must fix (§6.R4, §10)."""
    sys.stderr.write("resolve-config: " + msg + "\n")
    sys.exit(3)


def fmt(model):
    return "null" if model is None else model


def vendor_of(model):
    """Best-effort model-id -> vendor map (§9). Heuristic; None => unknown."""
    if not model:
        return None
    m = model.lower()
    if m.startswith("claude-"):
        return "anthropic"
    if m.startswith("gpt-"):
        return "openai"
    if len(m) >= 2 and m[0] == "o" and m[1].isdigit():  # o1, o3, o4-mini, ...
        return "openai"
    if m.startswith("gemini-"):
        return "google"
    if m.startswith("grok-"):
        return "xai"
    if m.startswith("mistral-") or m.startswith("mixtral-"):
        return "mistral"
    if m.startswith("llama"):
        return "meta"
    return None


def load_layer(path, label):
    """Return (data, found). Validates JSON shape; fails loudly on malformed."""
    if not path or not os.path.exists(path):
        return None, False
    try:
        with open(path, "r") as f:
            raw = f.read()
    except OSError as e:
        fail("cannot read %s config file '%s': %s" % (label, path, e))
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as e:
        fail("malformed JSON in %s config file '%s': %s" % (label, path, e))
    if not isinstance(data, dict):
        fail("%s config file '%s' must contain a JSON object at top level" % (label, path))
    agents = data.get("agents")
    if agents is not None and not isinstance(agents, dict):
        fail("%s config file '%s': 'agents' must be an object" % (label, path))
    if isinstance(agents, dict):
        for name, cfg in agents.items():
            if not isinstance(cfg, dict):
                fail("%s config file '%s': agents.%s must be an object" % (label, path, name))
            if "model" in cfg and not (cfg["model"] is None or isinstance(cfg["model"], str)):
                fail("%s config file '%s': agents.%s.model must be a string or null" % (label, path, name))
    if "version" in data and not isinstance(data["version"], int):
        fail("%s config file '%s': 'version' must be an integer" % (label, path))
    return data, True


# --- Deep-merge defaults <- global <- project (§5.1, §6.R3) -----------------
resolved = {
    "version": DEFAULTS["version"],
    "agents": {name: dict(cfg) for name, cfg in DEFAULTS["agents"].items()},
}
sources = ["defaults"]
advisories = []

for label, path in (("global", GLOBAL_PATH), ("project", PROJECT_PATH)):
    data, found = load_layer(path, label)
    if not found:
        continue  # an absent layer contributes nothing

    contributed = False

    if "version" in data:
        resolved["version"] = data["version"]
        contributed = True

    for name, cfg in (data.get("agents") or {}).items():
        if name not in KNOWN_AGENTS:
            advisories.append("unknown agent '%s' in %s config ignored" % (name, label))
            continue
        if "model" in cfg:
            old = resolved["agents"][name]["model"]
            new = cfg["model"]
            resolved["agents"][name]["model"] = new
            contributed = True
            if old != new:
                advisories.append(
                    "%s.model overridden by %s config: %s -> %s"
                    % (name, label, fmt(old), fmt(new))
                )

    for key in data:
        if key not in KNOWN_TOP_KEYS:
            advisories.append("unknown top-level key '%s' in %s config ignored" % (key, label))

    # Record the source. Distinguish found-but-empty from not-found (§Q2): a
    # found layer that set nothing recognized is tagged "(empty)"; a not-found
    # layer never appears in sources at all.
    entry = "%s:%s" % (label, path)
    if not contributed:
        entry += " (empty)"
    sources.append(entry)

# --- Same-vendor reviewer collapse advisory (§9, soft, never blocks) --------
rev_model = resolved["agents"]["reviewer"]["model"]
rev_vendor = vendor_of(rev_model)
if rev_vendor is not None:
    for impl in IMPLEMENTERS:
        if vendor_of(resolved["agents"][impl]["model"]) == rev_vendor:
            advisories.append(
                "reviewer model '%s' shares vendor '%s' with %s ('%s'); "
                "cross-vendor review is not guaranteed (soft advisory, non-blocking)"
                % (rev_model, rev_vendor, impl, resolved["agents"][impl]["model"])
            )
            break

# --- Emit -------------------------------------------------------------------
out = {
    "version": resolved["version"],
    "agents": resolved["agents"],
    "_meta": {"sources": sources, "advisories": advisories},
}
# Human diagnostics on stderr (silent when there are none); resolved doc on stdout.
for a in advisories:
    sys.stderr.write("resolve-config: " + a + "\n")
sys.stdout.write(json.dumps(out, indent=2) + "\n")
PYEOF
