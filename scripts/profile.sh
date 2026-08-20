#!/bin/bash

# Canonical runtime contract shared by setup, diagnostics, and launch.
MODEL_BASE_KEY="qwen/qwen3.8-27b"
MODEL_VARIANT_KEY="qwen/qwen3.8-27b@q8_0"
MODEL_ID="qwen3.8-27b-gguf-q8-mtp"
MODEL_FORMAT="gguf"
MODEL_QUANTIZATION="Q8_0"
MODEL_BITS="8"
CONTEXT_LENGTH="131072"
MIN_MEMORY_GIB="64"
MODEL_DOWNLOAD_MIN_FREE_GIB="35"
MIN_OPENCODE_VERSION="1.18.17"
TESTED_OPENCODE_VERSION="1.18.17"
TESTED_LM_STUDIO_VERSION="0.4.21+2"
TESTED_LLAMA_RUNTIME_VERSION="2.28.2"
LMSTUDIO_URL="http://127.0.0.1:1234"
SESSION_LOCK_DIR="${TMPDIR:-/tmp}"
SESSION_LOCK_DIR="${SESSION_LOCK_DIR%/}/opencode-${MODEL_ID}.lock"

resolve_lms_bin() {
  local candidate
  candidate="$(command -v lms || true)"
  if [[ -n "$candidate" && -x "$candidate" ]]; then
    printf '%s\n' "$candidate"
  elif [[ -x "$HOME/.lmstudio/bin/lms" ]]; then
    printf '%s\n' "$HOME/.lmstudio/bin/lms"
  fi
}

resolve_opencode_bin() {
  local candidate
  candidate="$(command -v opencode || true)"
  if [[ -n "$candidate" && -x "$candidate" ]]; then
    printf '%s\n' "$candidate"
  fi
}

physical_memory_gib() {
  sysctl -n hw.memsize 2>/dev/null | awk '{printf "%.0f\n", $1 / 1073741824}'
}

version_at_least() {
  local actual="$1"
  local required="$2"
  awk -v actual="$actual" -v required="$required" '
    BEGIN {
      sub(/[^0-9.].*$/, "", actual)
      sub(/[^0-9.].*$/, "", required)
      actual_count = split(actual, actual_parts, ".")
      required_count = split(required, required_parts, ".")
      count = actual_count > required_count ? actual_count : required_count
      for (i = 1; i <= count; i++) {
        actual_value = actual_parts[i] + 0
        required_value = required_parts[i] + 0
        if (actual_value > required_value) exit 0
        if (actual_value < required_value) exit 1
      }
      exit 0
    }
  '
}

model_is_installed() {
  local installed_json
  installed_json="$("$LMS_BIN" ls "$MODEL_BASE_KEY" --json 2>/dev/null || true)"
  jq -e \
    --arg key "$MODEL_VARIANT_KEY" \
    --arg format "$MODEL_FORMAT" \
    --arg quantization "$MODEL_QUANTIZATION" \
    --argjson bits "$MODEL_BITS" \
    'any(.[];
      .modelKey == $key and
      .format == $format and
      .quantization.name == $quantization and
      .quantization.bits == $bits)' \
    <<<"$installed_json" >/dev/null 2>&1
}

model_is_selected() {
  local selected_json
  selected_json="$("$LMS_BIN" ls --json 2>/dev/null || true)"
  jq -e \
    --arg base "$MODEL_BASE_KEY" \
    --arg variant "$MODEL_VARIANT_KEY" \
    --arg format "$MODEL_FORMAT" \
    --arg quantization "$MODEL_QUANTIZATION" \
    --argjson bits "$MODEL_BITS" \
    'any(.[];
      .modelKey == $base and
      .selectedVariant == $variant and
      .format == $format and
      .quantization.name == $quantization and
      .quantization.bits == $bits)' \
    <<<"$selected_json" >/dev/null 2>&1
}

server_is_ready() {
  curl -fsS "$LMSTUDIO_URL/v1/models" >/dev/null 2>&1
}

loaded_context() {
  curl -fsS "$LMSTUDIO_URL/api/v1/models" 2>/dev/null | jq -r --arg id "$MODEL_ID" \
    '[.models[].loaded_instances[]? | select(.id == $id)][0].config.context_length // empty'
}

loaded_status() {
  "$LMS_BIN" ps --json 2>/dev/null | jq -r --arg id "$MODEL_ID" \
    'map(select(.identifier == $id))[0].status // empty'
}

loaded_is_required_variant() {
  curl -fsS "$LMSTUDIO_URL/api/v1/models" 2>/dev/null | jq -e \
    --arg id "$MODEL_ID" \
    --arg key "$MODEL_VARIANT_KEY" \
    --arg format "$MODEL_FORMAT" \
    --arg quantization "$MODEL_QUANTIZATION" \
    --argjson bits "$MODEL_BITS" \
    --argjson context "$CONTEXT_LENGTH" \
    'any(.models[];
      .selected_variant == $key and
      .format == $format and
      .quantization.name == $quantization and
      .quantization.bits_per_weight == $bits and
      any(.loaded_instances[]?;
        .id == $id and
        .config.context_length == $context and
        .config.parallel == 1 and
        .config.flash_attention == true and
        .config.speculative_draft_mtp == true))' >/dev/null 2>&1
}

active_opencode_session_pids() {
  local pid command
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    if [[ "$command" == *"--model lmstudio/qwen3.8-27b"* ]]; then
      printf '%s\n' "$pid"
    fi
  done < <(pgrep -x opencode 2>/dev/null || true)
}

active_opencode_session_count() {
  local pids
  pids="$(active_opencode_session_pids)"
  if [[ -z "$pids" ]]; then
    printf '0\n'
  else
    printf '%s\n' "$pids" | wc -l | tr -d ' '
  fi
}

acquire_session_lock() {
  local owner_pid
  if mkdir "$SESSION_LOCK_DIR" 2>/dev/null; then
    printf '%s\n' "$$" >"$SESSION_LOCK_DIR/pid"
    return 0
  fi

  owner_pid="$(sed -n '1p' "$SESSION_LOCK_DIR/pid" 2>/dev/null || true)"
  if [[ "$owner_pid" =~ ^[0-9]+$ ]] && kill -0 "$owner_pid" 2>/dev/null; then
    return 1
  fi

  rm -f "$SESSION_LOCK_DIR/pid"
  rmdir "$SESSION_LOCK_DIR" 2>/dev/null || return 1
  mkdir "$SESSION_LOCK_DIR" || return 1
  printf '%s\n' "$$" >"$SESSION_LOCK_DIR/pid"
}

release_session_lock() {
  local owner_pid
  owner_pid="$(sed -n '1p' "$SESSION_LOCK_DIR/pid" 2>/dev/null || true)"
  if [[ "$owner_pid" == "$$" ]]; then
    rm -f "$SESSION_LOCK_DIR/pid"
    rmdir "$SESSION_LOCK_DIR" 2>/dev/null || true
  fi
}
