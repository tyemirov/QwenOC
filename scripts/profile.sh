#!/bin/bash

# Canonical runtime contract shared by setup, diagnostics, and launch.
PROFILE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODEL_TIER_MAP="$PROFILE_ROOT/config/model-tiers.tsv"
MODEL_BASE_KEY="qwen/qwen3.8-27b"
MODEL_FORMAT="gguf"
MIN_SUPPORTED_MEMORY_GIB="32"
MIN_OPENCODE_VERSION="1.18.17"
TESTED_OPENCODE_VERSION="1.18.17"
TESTED_LM_STUDIO_VERSION="0.4.21+2"
TESTED_LLAMA_RUNTIME_VERSION="2.28.2"
LMSTUDIO_URL="http://127.0.0.1:1234"

physical_memory_gib() {
  sysctl -n hw.memsize 2>/dev/null | awk '{printf "%.0f\n", $1 / 1073741824}'
}

validate_model_tier_map() {
  awk -F '\t' -v minimum_memory="$MIN_SUPPORTED_MEMORY_GIB" '
    /^#/ || NF == 0 { next }
    NF != 11 { exit 1 }
    $1 !~ /^[0-9]+$/ || $4 !~ /^[0-9]+$/ { exit 1 }
    $7 !~ /^[0-9]+$/ || $8 !~ /^[0-9]+$/ || $9 !~ /^[0-9]+$/ || $10 !~ /^[0-9]+$/ { exit 1 }
    $11 !~ /^[0-9]+([.][0-9]+)?$/ { exit 1 }
    $2 == "" || $3 == "" || $5 == "" || $6 == "" { exit 1 }
    $7 <= $8 || $7 <= $9 { exit 1 }
    count > 0 && $1 >= previous_memory { exit 1 }
    {
      previous_memory = $1
      count++
    }
    END { if (count == 0 || previous_memory != minimum_memory) exit 1 }
  ' "$MODEL_TIER_MAP"
}

select_model_profile_for_memory() {
  local memory_gib="$1"
  local profile_row

  if [[ ! "$memory_gib" =~ ^[0-9]+$ ]] || ! validate_model_tier_map; then
    return 1
  fi

  profile_row="$(awk -F '\t' -v memory="$memory_gib" '
    /^#/ || NF == 0 { next }
    memory >= $1 { print; exit }
  ' "$MODEL_TIER_MAP")"
  [[ -n "$profile_row" ]] || return 1

  IFS=$'\t' read -r \
    MIN_MEMORY_GIB \
    PROFILE_TIER \
    MODEL_QUANTIZATION \
    MODEL_BITS \
    MODEL_VARIANT_KEY \
    MODEL_ID \
    CONTEXT_LENGTH \
    OUTPUT_LIMIT \
    COMPACTION_RESERVED \
    MODEL_DOWNLOAD_MIN_FREE_GIB \
    MODEL_SIZE_GIB <<<"$profile_row"

  MODEL_DISPLAY_NAME="Qwen 3.8 27B GGUF ${MODEL_QUANTIZATION} + MTP"
  return 0
}

DETECTED_MEMORY_GIB="$(physical_memory_gib)"
HARDWARE_PROFILE_SUPPORTED=1
if ! select_model_profile_for_memory "$DETECTED_MEMORY_GIB"; then
  HARDWARE_PROFILE_SUPPORTED=0
  # Keep all contract variables defined so diagnostics can report the minimum tier.
  select_model_profile_for_memory "$MIN_SUPPORTED_MEMORY_GIB" || {
    printf 'Invalid or unreadable model tier map: %s\n' "$MODEL_TIER_MAP" >&2
    return 1 2>/dev/null || exit 1
  }
fi

SESSION_LOCK_DIR="${TMPDIR:-/tmp}"
SESSION_LOCK_DIR="${SESSION_LOCK_DIR%/}/opencode-qwen3.8-27b.lock"

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

runtime_opencode_config_content() {
  jq -c \
    --arg model_id "$MODEL_ID" \
    --arg model_name "$MODEL_DISPLAY_NAME" \
    --argjson context "$CONTEXT_LENGTH" \
    --argjson output "$OUTPUT_LIMIT" \
    --argjson reserved "$COMPACTION_RESERVED" \
    '
      .provider.lmstudio.models["qwen3.8-27b"].id = $model_id |
      .provider.lmstudio.models["qwen3.8-27b"].name = $model_name |
      .provider.lmstudio.models["qwen3.8-27b"].limit.context = $context |
      .provider.lmstudio.models["qwen3.8-27b"].limit.output = $output |
      .compaction.reserved = $reserved |
      {
        model,
        small_model,
        provider: {lmstudio: .provider.lmstudio},
        compaction
      }
    ' "$PROFILE_ROOT/opencode.jsonc"
}

configure_opencode_environment() {
  export OPENCODE_CONFIG="$PROFILE_ROOT/opencode.jsonc"
  export OPENCODE_CONFIG_DIR="$PROFILE_ROOT/.opencode"
  export OPENCODE_CONFIG_CONTENT
  OPENCODE_CONFIG_CONTENT="$(runtime_opencode_config_content)"
  export OPENCODE_EXPERIMENTAL_LSP_TOOL=true
  export OPENCODE_ENABLE_EXA=true
  export OPENCODE_DISABLE_CLAUDE_CODE_SKILLS=true
  export QWENOC_OUTPUT_LIMIT="$OUTPUT_LIMIT"
  export QWENOC_PROFILE_TIER="$PROFILE_TIER"
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
