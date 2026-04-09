#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
BASIC_JSON="${BASIC_JSON:-$ROOT_DIR/swe_bench_pro_js_ts_basic_10.json}"
REPO_CACHE_DIR="${REPO_CACHE_DIR:-$ROOT_DIR/repo_cache}"
LOG_DIR="${LOG_DIR:-$ROOT_DIR/logs/repo_clone}"

command -v jq >/dev/null 2>&1 || {
  echo "missing required command: jq" >&2
  exit 1
}

command -v git >/dev/null 2>&1 || {
  echo "missing required command: git" >&2
  exit 1
}

[[ -f "$BASIC_JSON" ]] || {
  echo "missing basic json: $BASIC_JSON" >&2
  exit 1
}

mkdir -p "$REPO_CACHE_DIR"
mkdir -p "$LOG_DIR"

repo_is_healthy() {
  local cache_dir="$1"

  [[ -d "$cache_dir/.git" ]] || return 1
  git -C "$cache_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  git -C "$cache_dir" rev-parse HEAD >/dev/null 2>&1 || return 1
  git -C "$cache_dir" status --porcelain >/dev/null 2>&1 || return 1
  return 0
}

mirror_is_healthy() {
  local cache_dir="$1"
  [[ -d "$cache_dir" ]] || return 1
  git -C "$cache_dir" rev-parse --is-bare-repository 2>/dev/null | grep -qx 'true'
}

clone_or_update_repo() {
  local repo_slug="$1"
  local cache_name="${repo_slug//\//__}"
  local cache_dir="$REPO_CACHE_DIR/$cache_name"
  local log_file="$LOG_DIR/${cache_name}.log"

  if mirror_is_healthy "$cache_dir"; then
    echo "[update] $repo_slug"
    git -C "$cache_dir" remote set-url origin "https://github.com/${repo_slug}.git"
    git -C "$cache_dir" remote update --prune 2>&1 | tee "$log_file"
  elif repo_is_healthy "$cache_dir"; then
    echo "[reclone-as-mirror] $repo_slug"
    rm -rf "$cache_dir"
    git clone --mirror "https://github.com/${repo_slug}.git" "$cache_dir" 2>&1 | tee "$log_file"
  elif [[ -e "$cache_dir" ]]; then
    echo "[reclone] $repo_slug"
    rm -rf "$cache_dir"
    git clone --mirror "https://github.com/${repo_slug}.git" "$cache_dir" 2>&1 | tee "$log_file"
  else
    echo "[clone] $repo_slug"
    git clone --mirror "https://github.com/${repo_slug}.git" "$cache_dir" 2>&1 | tee "$log_file"
  fi
}

failures=0

while IFS= read -r repo_slug; do
  [[ -n "$repo_slug" ]] || continue
  if ! clone_or_update_repo "$repo_slug"; then
    echo "[failed] $repo_slug"
    failures=$((failures + 1))
  fi
done < <(jq -r '.[].repo' "$BASIC_JSON" | sort -u)

echo "done: repo cache ready at $REPO_CACHE_DIR"
echo "clone logs: $LOG_DIR"
exit "$failures"
