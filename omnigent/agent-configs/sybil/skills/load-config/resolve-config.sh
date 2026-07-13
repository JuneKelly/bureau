#!/usr/bin/env bash
set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "resolve-config: jq not found — install jq (e.g. brew install jq)" >&2; exit 1; }

# Resolve symlinks so SCRIPT_DIR points at the real script location even when
# invoked via a symlink (readlink without -f for macOS/BSD portability).
_src="${BASH_SOURCE[0]}"
while [ -L "$_src" ]; do
  _dir="$(cd "$(dirname "$_src")" && pwd)"
  _src="$(readlink "$_src")"
  case "$_src" in /*) ;; *) _src="$_dir/$_src" ;; esac
done
SCRIPT_DIR="$(cd "$(dirname "$_src")" && pwd)"

GLOBAL_CONFIG="${SYBIL_GLOBAL_CONFIG:-${HOME:-}/.config/omnigent-sybil/config.json}"

if [ -n "${SYBIL_PROJECT_CONFIG:-}" ]; then
  PROJECT_CONFIG="${SYBIL_PROJECT_CONFIG}"
else
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || repo_root=""
  PROJECT_CONFIG="${repo_root:+${repo_root}/.sybil-config.json}"
fi

files=("${SCRIPT_DIR}/defaults.json")
[ -f "${GLOBAL_CONFIG}" ] && files+=("${GLOBAL_CONFIG}")
[ -n "${PROJECT_CONFIG}" ] && [ -f "${PROJECT_CONFIG}" ] && files+=("${PROJECT_CONFIG}")

jq -s 'reduce .[] as $x ({}; . * $x)' "${files[@]}"
