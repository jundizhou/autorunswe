#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
BASIC_JSON="${BASIC_JSON:-$ROOT_DIR/swe_bench_pro_js_ts_basic_10.json}"
FORBIDDEN_FULL_JSON="${FORBIDDEN_FULL_JSON:-$ROOT_DIR/swe_bench_pro_js_ts_full_10.json}"
SCHEMA_JSON="${SCHEMA_JSON:-$ROOT_DIR/codex_result_schema.json}"
CODEX_BIN="${CODEX_BIN:-codex}"
MODEL="${MODEL:-gpt-5.4}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-2}"
REPO_CACHE_DIR="${REPO_CACHE_DIR:-$ROOT_DIR/repo_cache}"
CLAW_SKILLS_ROOT="${CLAW_SKILLS_ROOT:-/Users/jundi/PycharmProjects/claw-skills}"
SECOND_PASS_SKILL_PATH="${SECOND_PASS_SKILL_PATH:-/Users/jundi/PycharmProjects/claw-skills/skills/debug-orchestrator-fix/SKILL.md}"
SECOND_PASS_SKILL_DIR="${SECOND_PASS_SKILL_DIR:-$(cd "$(dirname "$SECOND_PASS_SKILL_PATH")" && pwd -P)}"
SECOND_PASS_SETUP_SCRIPT="${SECOND_PASS_SETUP_SCRIPT:-$SECOND_PASS_SKILL_DIR/scripts/setup.py}"
SECOND_PASS_ORCHESTRATOR_SCRIPT="${SECOND_PASS_ORCHESTRATOR_SCRIPT:-$SECOND_PASS_SKILL_DIR/scripts/orchestrate_debug.py}"
SECOND_PASS_AGENT_NAME="${SECOND_PASS_AGENT_NAME:-codex}"
SECOND_PASS_CODEX_ACP_COMMAND="${SECOND_PASS_CODEX_ACP_COMMAND:-/tmp/codex-acp-local/node_modules/@zed-industries/codex-acp-darwin-arm64/bin/codex-acp}"
SECOND_PASS_DATASET_NAME="${SECOND_PASS_DATASET_NAME:-SWE-bench_Pro}"
SECOND_PASS_SETUP_TIMEOUT_SECONDS="${SECOND_PASS_SETUP_TIMEOUT_SECONDS:-900}"
SECOND_PASS_ORCHESTRATOR_TIMEOUT_SECONDS="${SECOND_PASS_ORCHESTRATOR_TIMEOUT_SECONDS:-3600}"
FIRST_ONLY_DEFAULT="${FIRST_ONLY_DEFAULT:-1}"
RUN_PATCH_CHECK="${RUN_PATCH_CHECK:-1}"
PATCH_CHECK_PYTHON="${PATCH_CHECK_PYTHON:-/Users/jundi/PyCharmMiscProject/SWE-bench_Pro-os/.venv/bin/python}"
PATCH_CHECK_SCRIPT="${PATCH_CHECK_SCRIPT:-/Users/jundi/PyCharmMiscProject/SWE-bench_Pro-os/helper_code/run_single_patch_check.py}"
PATCH_CHECK_OUTPUT_ROOT="${PATCH_CHECK_OUTPUT_ROOT:-/tmp/swe-bench-pro-single-patch-eval}"
PATCH_CHECK_REPORT_FILE="${PATCH_CHECK_REPORT_FILE:-$ROOT_DIR/logs/patch_check_results.md}"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

require_file() {
  [[ -f "$1" ]] || {
    echo "missing required file: $1" >&2
    exit 1
  }
}

require_dir() {
  [[ -d "$1" ]] || {
    echo "missing required directory: $1" >&2
    exit 1
  }
}

ensure_guardrails() {
  require_cmd "$CODEX_BIN"
  require_cmd jq
  require_cmd git
  require_file "$BASIC_JSON"
  require_file "$SCHEMA_JSON"
  require_dir "$REPO_CACHE_DIR"

  if [[ -e "$FORBIDDEN_FULL_JSON" ]]; then
    echo "refusing to run while forbidden full json exists: $FORBIDDEN_FULL_JSON" >&2
    exit 1
  fi

  [[ -n "$SECOND_PASS_SKILL_PATH" ]] || {
    echo "SECOND_PASS_SKILL_PATH is required" >&2
    exit 1
  }

  require_file "$SECOND_PASS_SKILL_PATH"
  require_file "$SECOND_PASS_SETUP_SCRIPT"
  require_file "$SECOND_PASS_ORCHESTRATOR_SCRIPT"
  if [[ "$SECOND_PASS_AGENT_NAME" == "codex" ]]; then
    require_file "$SECOND_PASS_CODEX_ACP_COMMAND"
  fi

  if [[ "$RUN_PATCH_CHECK" == "1" ]]; then
    require_file "$PATCH_CHECK_PYTHON"
    require_file "$PATCH_CHECK_SCRIPT"
  fi

  case "$SECOND_PASS_SKILL_PATH" in
    "$CLAW_SKILLS_ROOT"/*) ;;
    *)
      echo "SECOND_PASS_SKILL_PATH must be under $CLAW_SKILLS_ROOT" >&2
      exit 1
      ;;
  esac
}

get_instance_ids() {
  if [[ "$#" -gt 0 ]]; then
    printf '%s\n' "$@"
  elif [[ "$FIRST_ONLY_DEFAULT" == "1" ]]; then
    jq -r '.[0].instance_id' "$BASIC_JSON"
  else
    jq -r '.[].instance_id' "$BASIC_JSON"
  fi
}

extract_bug_json() {
  local instance_id="$1"
  jq -e --arg id "$instance_id" '.[] | select(.instance_id == $id)' "$BASIC_JSON"
}

prepare_repo() {
  local repo_slug="$1"
  local base_commit="$2"
  local repo_dir="$3"
  local cache_dir

  cache_dir="$(cache_dir_for_repo "$repo_slug")"
  ensure_repo_cache "$repo_slug" "$cache_dir"

  rm -rf "$repo_dir"
  mkdir -p "$(dirname "$repo_dir")"
  git clone --no-checkout "$cache_dir" "$repo_dir" >/dev/null
  git -C "$repo_dir" remote set-url origin "https://github.com/${repo_slug}.git"
  if ! git -C "$repo_dir" cat-file -e "${base_commit}^{commit}" 2>/dev/null; then
    git -C "$repo_dir" fetch origin "$base_commit" >/dev/null
  fi
  git -C "$repo_dir" checkout --detach "$base_commit"
  git -C "$repo_dir" reset --hard "$base_commit" >/dev/null
  git -C "$repo_dir" clean -fd >/dev/null
}

cache_dir_for_repo() {
  local repo_slug="$1"
  local cache_name="${repo_slug//\//__}"
  printf '%s\n' "$REPO_CACHE_DIR/$cache_name"
}

ensure_repo_cache() {
  local repo_slug="$1"
  local cache_dir="$2"

  if [[ ! -d "$cache_dir" ]]; then
    echo "missing repo cache for $repo_slug: $cache_dir" >&2
    echo "run ./clone_all_repos.sh first" >&2
    exit 1
  fi

  if ! git -C "$cache_dir" rev-parse --is-bare-repository 2>/dev/null | grep -qx 'true'; then
    echo "repo cache is not a bare mirror: $cache_dir" >&2
    echo "rebuild it with ./clone_all_repos.sh" >&2
    exit 1
  fi
}

warm_cache() {
  "$ROOT_DIR/clone_all_repos.sh"
}

run_with_timeout() {
  local seconds="$1"
  shift

  if command -v timeout >/dev/null 2>&1; then
    timeout "$seconds" "$@"
    return $?
  fi

  if command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$seconds" "$@"
    return $?
  fi

  python3 - "$seconds" "$@" <<'PY'
import subprocess
import sys

timeout_seconds = int(sys.argv[1])
argv = sys.argv[2:]
try:
    completed = subprocess.run(argv, check=False, timeout=timeout_seconds)
except subprocess.TimeoutExpired:
    raise SystemExit(124)
raise SystemExit(completed.returncode)
PY
}

build_prompt() {
  local pass_mode="$1"
  local instance_id="$2"
  local patch_rel="$3"
  local skill_path="$4"

  cat <<EOF
You are a dedicated patch-generation worker running in a fresh Codex session for exactly one SWE-bench Pro bug.

HARD GATES:
1. Read bug description ONLY from ./input/basic_bug.json.
2. Do NOT read any full dataset file. Do NOT search for files with "full" in the name.
3. Work only inside ./repo plus the single metadata file ./input/basic_bug.json.
4. If you produce code changes, write the patch file at ${patch_rel} before you finish.
5. Do not stop at analysis. Your job is to complete one isolated repair attempt.
6. Treat this task as fully isolated. Do not rely on previous runs or previous sessions.
7. Final response must be valid JSON matching the provided schema.

PASS MODE: ${pass_mode}
INSTANCE ID: ${instance_id}
EOF

  if [[ "$pass_mode" == "no_skill" ]]; then
    cat <<EOF

NO_SKILL HARD GATE:
- You MUST NOT read, reference, mention, or use ${CLAW_SKILLS_ROOT}.
- If you think a skill might help, ignore that and continue without it.
EOF
  else
    cat <<EOF

WITH_SKILL HARD GATE:
- Before making code changes, you MUST read and use this exact skill path: ${skill_path}
- Do not use any other skill path outside ${CLAW_SKILLS_ROOT}
- In the final JSON, set "used_skill_path" to the exact path above.
EOF
  fi

  cat <<EOF

EXECUTION REQUIREMENTS:
- Read ./input/basic_bug.json first.
- Inspect ./repo and make the minimal reasonable fix.
- Prefer the smallest patch that satisfies the issue statement and test expectations.
- Do not exhaustively explore the whole repository when the relevant files are already clear.
- If you changed code, generate the patch with:
  git -C ./repo diff --binary --full-index > ${patch_rel}
- If tests are cheap and obvious, run them. If not, do not block on exhaustive testing.
- Do not read or mention any deleted or forbidden full-data file.

FINAL JSON REQUIREMENTS:
- status may be "patched" if ${patch_rel} exists and is non-empty, otherwise use "failed"
- instance_id must be "${instance_id}"
- pass_mode must be "${pass_mode}"
- read_basic_only must be true
- read_full_json must be false
- patch_path must be "${patch_rel}"
- summary should be short and factual
EOF
}

run_codex_once() {
  local pass_mode="$1"
  local instance_id="$2"
  local run_dir="$3"
  local prompt_file="$4"
  local result_file="$5"
  local events_file="$6"

  local -a extra_args=()
  if [[ "$pass_mode" == "with_skill" ]]; then
    extra_args+=(--add-dir "$CLAW_SKILLS_ROOT")
  fi

  "$CODEX_BIN" -a never exec \
    -m "$MODEL" \
    -s workspace-write \
    --skip-git-repo-check \
    -C "$run_dir" \
    --json \
    --color never \
    --output-schema "$SCHEMA_JSON" \
    -o "$result_file" \
    "${extra_args[@]}" \
    - < "$prompt_file" > "$events_file"
}

resolve_second_pass_python() {
  local venv_python="$SECOND_PASS_SKILL_DIR/.venv/bin/python"
  if [[ -x "$venv_python" ]]; then
    printf '%s\n' "$venv_python"
    return 0
  fi

  if command -v python3 >/dev/null 2>&1; then
    python3 - <<'PY' >/dev/null 2>&1
import sys
raise SystemExit(0 if sys.version_info[:2] >= (3, 11) else 1)
PY
    if [[ "$?" -eq 0 ]]; then
      command -v python3
      return 0
    fi
  fi

  echo "no Python >= 3.11 available for second-pass orchestrator" >&2
  return 1
}

setup_second_pass_skill() {
  local setup_python
  setup_python="$(resolve_second_pass_python)"
  run_with_timeout "$SECOND_PASS_SETUP_TIMEOUT_SECONDS" "$setup_python" "$SECOND_PASS_SETUP_SCRIPT" >/dev/null
}

build_issue_text() {
  local bug_json="$1"
  local problem_statement requirements interface
  problem_statement="$(printf '%s\n' "$bug_json" | jq -r '.problem_statement')"
  requirements="$(printf '%s\n' "$bug_json" | jq -r '.requirements')"
  interface="$(printf '%s\n' "$bug_json" | jq -r '.interface')"

  cat <<EOF
$problem_statement

### Requirements
$requirements

### Interface
$interface
EOF
}

run_with_skill_orchestrator_once() {
  local instance_id="$1"
  local run_dir="$2"
  local repo_dir="$3"
  local bug_json="$4"
  local issue_file="$5"
  local events_file="$6"
  local patch_file="$7"
  local result_file="$8"

  local skill_python
  skill_python="$(resolve_second_pass_python)"

  mkdir -p "$repo_dir/.orchestration"
  cp "$issue_file" "$repo_dir/.orchestration/issue.md"

  local acpx_live_log="$run_dir/acpx_live.log"
  local acpx_raw_log="$run_dir/acpx_raw.jsonl"
  local final_result_candidates=(
    "$repo_dir/.orchestration/artifacts/contracts/final-result.json"
    "$repo_dir/.orchestration/final-result.json"
  )

  local orchestrator_rc=0
  if ! run_with_timeout "$SECOND_PASS_ORCHESTRATOR_TIMEOUT_SECONDS" \
    env ACPX_BIN="$SECOND_PASS_SKILL_DIR/node_modules/.bin/acpx" \
      CODEX_ACP_COMMAND="$SECOND_PASS_CODEX_ACP_COMMAND" \
    "$skill_python" "$SECOND_PASS_ORCHESTRATOR_SCRIPT" \
      --repo-path "$repo_dir" \
      --issue-file "$issue_file" \
      --bug-description "$(printf '%s\n' "$bug_json" | jq -r '.problem_statement')" \
      --agent-name "$SECOND_PASS_AGENT_NAME" \
      --instance-id "$instance_id" \
      --dataset-name "$SECOND_PASS_DATASET_NAME" \
      --repo-url "https://github.com/$(printf '%s\n' "$bug_json" | jq -r '.repo').git" \
      --clone-mode use_local \
      --acpx-live-log-file "$acpx_live_log" \
      --acpx-debug-raw-jsonrpc-file "$acpx_raw_log" \
      > "$events_file" 2>&1; then
    orchestrator_rc=$?
  fi

  git -C "$repo_dir" diff --binary --full-index > "$patch_file"

  local final_result_path=""
  local candidate
  for candidate in "${final_result_candidates[@]}"; do
    if [[ -f "$candidate" ]]; then
      final_result_path="$candidate"
      break
    fi
  done

  jq -n \
    --arg id "$instance_id" \
    --arg mode "with_skill" \
    --arg patch "./out/fix.patch" \
    --arg skill "$SECOND_PASS_SKILL_PATH" \
    --arg final_result_path "$final_result_path" \
    --arg final_outcome "$(if [[ -n "$final_result_path" ]]; then jq -r '.outcome // ""' "$final_result_path"; fi)" \
    --arg final_submit_result "$(if [[ -n "$final_result_path" ]]; then jq -r '.submit_result // ""' "$final_result_path"; fi)" \
    --arg orchestrator_rc "$orchestrator_rc" \
    --arg status "$(if [[ -s "$patch_file" ]]; then printf 'patched'; else printf 'failed'; fi)" \
    '{
      status: $status,
      instance_id: $id,
      pass_mode: $mode,
      read_basic_only: true,
      read_full_json: false,
      patch_path: $patch,
      used_skill_path: $skill,
      summary: (
        (if $status == "patched" then "patch generated via debug-orchestrator-fix" else "debug-orchestrator-fix run completed without patch" end)
        + "; orchestrator_rc=" + $orchestrator_rc
        + (if $final_outcome != "" then "; outcome=" + $final_outcome else "" end)
        + (if $final_submit_result != "" then "; submit_result=" + $final_submit_result else "" end)
      ),
      final_result_path: $final_result_path
    }' > "$result_file"

  return 0
}

validate_forbidden_access() {
  local pass_mode="$1"
  local events_file="$2"
  local result_file="$3"

  if [[ "$pass_mode" == "no_skill" ]]; then
    if grep -Fq "$CLAW_SKILLS_ROOT" "$events_file" "$result_file"; then
      echo "forbidden claw-skills reference detected in no_skill pass" >&2
      return 1
    fi
  else
    if ! jq -e --arg p "$SECOND_PASS_SKILL_PATH" '.used_skill_path == $p' "$result_file" >/dev/null; then
      echo "with_skill pass did not report the expected skill path" >&2
      return 1
    fi
  fi
}

validate_result_json() {
  local instance_id="$1"
  local pass_mode="$2"
  local patch_rel="$3"
  local result_file="$4"

  if [[ "$pass_mode" == "with_skill" ]]; then
    jq -e \
      --arg id "$instance_id" \
      --arg mode "$pass_mode" \
      --arg patch "$patch_rel" \
      '
        (.status == "patched" or .status == "failed") and
        .instance_id == $id and
        .pass_mode == $mode and
        .read_basic_only == true and
        .read_full_json == false and
        .patch_path == $patch
      ' "$result_file" >/dev/null
  else
    jq -e \
      --arg id "$instance_id" \
      --arg mode "$pass_mode" \
      --arg patch "$patch_rel" \
      '
        .status == "patched" and
        .instance_id == $id and
        .pass_mode == $mode and
        .read_basic_only == true and
        .read_full_json == false and
        .patch_path == $patch
      ' "$result_file" >/dev/null
  fi
}

validate_patch() {
  local pass_mode="$1"
  local repo_dir="$2"
  local patch_file="$3"
  local base_commit="$4"

  if [[ "$pass_mode" == "with_skill" && ! -s "$patch_file" ]]; then
    return 0
  fi

  [[ -s "$patch_file" ]] || {
    echo "patch file missing or empty: $patch_file" >&2
    return 1
  }

  git -C "$repo_dir" reset --hard "$base_commit" >/dev/null
  git -C "$repo_dir" clean -fd >/dev/null
  git -C "$repo_dir" apply --check "$patch_file"
}

run_patch_check() {
  local instance_id="$1"
  local pass_mode="$2"
  local patch_file="$3"
  local patch_check_log="$ROOT_DIR/logs/$pass_mode/$instance_id.patch_check.txt"

  [[ "$RUN_PATCH_CHECK" == "1" ]] || return 0
  [[ -s "$patch_file" ]] || return 0

  echo "[$instance_id][$pass_mode] running benchmark patch check"
  "$PATCH_CHECK_PYTHON" "$PATCH_CHECK_SCRIPT" \
    --instance-id "$instance_id" \
    --patch-file "$patch_file" \
    --output-root "$PATCH_CHECK_OUTPUT_ROOT" \
    --report-file "$PATCH_CHECK_REPORT_FILE" \
    --report-label "$pass_mode" \
    > "$patch_check_log" 2>&1
}

run_one_pass() {
  local instance_id="$1"
  local pass_mode="$2"
  local repo_slug="$3"
  local base_commit="$4"
  local bug_json="$5"

  local final_patch_dir="$ROOT_DIR/patches/$pass_mode/$instance_id"
  local final_patch_file="$final_patch_dir/fix.patch"
  local final_result_file="$final_patch_dir/result.json"

  mkdir -p "$ROOT_DIR/logs/$pass_mode" "$final_patch_dir"

  if [[ "$pass_mode" == "with_skill" ]]; then
    if [[ -f "$final_result_file" ]]; then
      echo "[$instance_id][$pass_mode] already satisfied -> $final_result_file"
      return 0
    fi
  else
    if [[ -s "$final_patch_file" && -f "$final_result_file" ]]; then
      echo "[$instance_id][$pass_mode] already satisfied -> $final_patch_file"
      return 0
    fi
  fi

  local attempt
  for (( attempt=1; attempt<=MAX_ATTEMPTS; attempt++ )); do
    local attempt_dir="$ROOT_DIR/runs/$instance_id/$pass_mode/attempt-$attempt"
    local input_dir="$attempt_dir/input"
    local repo_dir="$attempt_dir/repo"
    local out_dir="$attempt_dir/out"
    local prompt_file="$attempt_dir/prompt.md"
    local result_file="$attempt_dir/result.json"
    local events_file="$attempt_dir/events.jsonl"
    local patch_file="$out_dir/fix.patch"
    local patch_rel="./out/fix.patch"
    local issue_file="$input_dir/issue.md"

    rm -rf "$attempt_dir"
    mkdir -p "$input_dir" "$out_dir"
    printf '%s\n' "$bug_json" | jq '.' > "$input_dir/basic_bug.json"
    build_issue_text "$bug_json" > "$issue_file"

    echo "[$instance_id][$pass_mode][attempt $attempt] preparing repo"
    prepare_repo "$repo_slug" "$base_commit" "$repo_dir"

    if [[ "$pass_mode" == "with_skill" ]]; then
      echo "[$instance_id][$pass_mode][attempt $attempt] running orchestrator"
      if ! setup_second_pass_skill; then
        echo "[$instance_id][$pass_mode][attempt $attempt] skill setup failed"
        continue
      fi
      if ! run_with_skill_orchestrator_once "$instance_id" "$attempt_dir" "$repo_dir" "$bug_json" "$issue_file" "$events_file" "$patch_file" "$result_file"; then
        echo "[$instance_id][$pass_mode][attempt $attempt] orchestrator result synthesis failed"
        continue
      fi
    else
      build_prompt "$pass_mode" "$instance_id" "$patch_rel" "$SECOND_PASS_SKILL_PATH" > "$prompt_file"
      echo "[$instance_id][$pass_mode][attempt $attempt] running codex"
      if ! run_codex_once "$pass_mode" "$instance_id" "$attempt_dir" "$prompt_file" "$result_file" "$events_file"; then
        echo "[$instance_id][$pass_mode][attempt $attempt] codex execution failed"
        continue
      fi
    fi

    if ! validate_forbidden_access "$pass_mode" "$events_file" "$result_file"; then
      echo "[$instance_id][$pass_mode][attempt $attempt] forbidden-access validation failed"
      continue
    fi

    if ! validate_result_json "$instance_id" "$pass_mode" "$patch_rel" "$result_file"; then
      echo "[$instance_id][$pass_mode][attempt $attempt] result-json validation failed"
      continue
    fi

    if ! validate_patch "$pass_mode" "$repo_dir" "$patch_file" "$base_commit"; then
      echo "[$instance_id][$pass_mode][attempt $attempt] patch validation failed"
      continue
    fi

    if ! run_patch_check "$instance_id" "$pass_mode" "$patch_file"; then
      echo "[$instance_id][$pass_mode][attempt $attempt] benchmark patch check failed"
      continue
    fi

    cp "$result_file" "$ROOT_DIR/logs/$pass_mode/$instance_id.result.json"
    cp "$events_file" "$ROOT_DIR/logs/$pass_mode/$instance_id.events.jsonl"
    cp "$result_file" "$final_result_file"
    if [[ -s "$patch_file" ]]; then
      cp "$patch_file" "$final_patch_file"
      echo "[$instance_id][$pass_mode] success -> $final_patch_file"
    else
      rm -f "$final_patch_file"
      echo "[$instance_id][$pass_mode] completed without patch -> $final_result_file"
    fi
    return 0
  done

  echo "[$instance_id][$pass_mode] failed after $MAX_ATTEMPTS attempts" >&2
  return 1
}

main() {
  ensure_guardrails

  if [[ "${1:-}" == "--warm-cache" ]]; then
    warm_cache
    exit 0
  fi

  local instance_id
  while IFS= read -r instance_id; do
    [[ -n "$instance_id" ]] || continue

    echo "=== processing $instance_id ==="
    local bug_json
    bug_json="$(extract_bug_json "$instance_id")" || {
      echo "instance_id not found in basic json: $instance_id" >&2
      exit 1
    }

    local repo_slug
    repo_slug="$(printf '%s\n' "$bug_json" | jq -r '.repo')"
    local base_commit
    base_commit="$(printf '%s\n' "$bug_json" | jq -r '.base_commit')"

    run_one_pass "$instance_id" "no_skill" "$repo_slug" "$base_commit" "$bug_json"
    run_one_pass "$instance_id" "with_skill" "$repo_slug" "$base_commit" "$bug_json"
  done < <(get_instance_ids "$@")
}

main "$@"
