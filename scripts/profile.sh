#!/bin/bash

# Canonical runtime contract shared by setup, diagnostics, and launch.
SCRIPT_PATH="${BASH_SOURCE[0]:-${(%):-%x}}"
PROFILE_ROOT="$(cd "$(dirname "${SCRIPT_PATH:-$0}")/.." && pwd)"
MODEL_TIER_MAP="$PROFILE_ROOT/configs/model-tiers.tsv"
INFERENCE_BACKEND="local"
MODEL_BASE_KEY="qwen/qwen3.8-27b"
MODEL_FORMAT="gguf"
MIN_SUPPORTED_MEMORY_GIB="32"
MIN_OPENCODE_VERSION="2.2.5"
OPENCODE_FORMULA="anomalyco/tap/opencode-v2"
TESTED_OPENCODE_VERSION="2.2.5"
TESTED_LM_STUDIO_VERSION="0.4.21+2"
TESTED_LLAMA_RUNTIME_VERSION="2.28.2"
LMSTUDIO_URL="http://127.0.0.1:1234"
GMAIL_MCP_SCOPES_REQUIRED="gmail.modify"
GOOGLE_DRIVE_MCP_SCOPES_REQUIRED="drive,documents,spreadsheets"
CHROME_APPLICATION_ID="com.google.Chrome"
CHROME_USER_DATA_DIR="$HOME/Library/Application Support/Google/Chrome"
CHROME_DEVTOOLS_ACTIVE_PORT="$CHROME_USER_DATA_DIR/DevToolsActivePort"
CHROME_MIN_AUTO_CONNECT_VERSION="144"

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
    COMPACTION_BUFFER \
    MODEL_DOWNLOAD_MIN_FREE_GIB \
    MODEL_SIZE_GIB <<<"$profile_row"

  MODEL_DISPLAY_NAME="Qwen 3.8 27B GGUF ${MODEL_QUANTIZATION} + MTP"
  return 0
}

initialize_local_profile() {
  DETECTED_MEMORY_GIB="$(physical_memory_gib)"
  HARDWARE_PROFILE_SUPPORTED=1
  if ! select_model_profile_for_memory "$DETECTED_MEMORY_GIB"; then
    HARDWARE_PROFILE_SUPPORTED=0
    # Keep diagnostic values defined on unsupported local hardware.
    select_model_profile_for_memory "$MIN_SUPPORTED_MEMORY_GIB" || {
      printf 'Invalid or unreadable model tier map: %s\n' "$MODEL_TIER_MAP" >&2
      return 1
    }
  fi
  OPENCODE_MODEL="lmstudio/qwen3.8-27b"
}

source "$PROFILE_ROOT/scripts/splash.sh"

initialize_inference_backend() {
  INFERENCE_BACKEND="$1"
  case "$INFERENCE_BACKEND" in
    local)
      initialize_local_profile
      ;;
    splash)
      initialize_splash_profile
      ;;
    *)
      printf 'Unknown backend: %s. Choose local or splash.\n' "$INFERENCE_BACKEND" >&2
      return 2
      ;;
  esac
}

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
      sub(/^opencode v/, "", actual)
      if (actual !~ /^[0-9]+([.][0-9]+)*$/ || required !~ /^[0-9]+([.][0-9]+)*$/) exit 1
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

require_opencode_version() {
  local version
  if ! version="$("$OPENCODE_BIN" --version 2>/dev/null | tail -1)"; then
    printf 'Could not read the OpenCode version: %s.\n' "$OPENCODE_BIN" >&2
    return 3
  fi
  if ! version_at_least "$version" "$MIN_OPENCODE_VERSION"; then
    printf 'OpenCode %s or newer is required; detected %s.\n' "$MIN_OPENCODE_VERSION" "$version" >&2
    return 3
  fi
}

chrome_version() {
  local chrome_bin
  chrome_bin="$(resolve_chrome_bin)"
  if [[ -n "$chrome_bin" ]]; then
    "$chrome_bin" --version 2>/dev/null | awk '{print $NF}'
  fi
}

resolve_chrome_bin() {
  local application_path
  local chrome_bin
  local lookup_script

  lookup_script="POSIX path of (path to application id \"$CHROME_APPLICATION_ID\")"
  application_path="$(osascript -e "$lookup_script" 2>/dev/null || true)"
  [[ -n "$application_path" ]] || return 1
  chrome_bin="${application_path%/}/Contents/MacOS/Google Chrome"
  [[ -x "$chrome_bin" ]] || return 1
  printf '%s\n' "$chrome_bin"
}

chrome_supports_auto_connect() {
  local version
  version="$(chrome_version)"
  [[ -n "$version" ]] && version_at_least "$version" "$CHROME_MIN_AUTO_CONNECT_VERSION"
}

chrome_auto_connect_is_ready() {
  local port=""
  local endpoint=""

  pgrep -x 'Google Chrome' >/dev/null 2>&1 || return 1
  [[ -r "$CHROME_DEVTOOLS_ACTIVE_PORT" ]] || return 1
  port="$(sed -n '1p' "$CHROME_DEVTOOLS_ACTIVE_PORT")"
  endpoint="$(sed -n '2p' "$CHROME_DEVTOOLS_ACTIVE_PORT")"
  [[ "$port" =~ ^[0-9]+$ ]] && [[ "$endpoint" == /devtools/browser/* ]]
}

newest_desktop_oauth_key() {
  local downloads_dir="${1:-$HOME/Downloads}"
  local candidate
  local newest=""

  while IFS= read -r -d '' candidate; do
    if ! jq -e '(.installed? | type) == "object"' "$candidate" >/dev/null 2>&1; then
      continue
    fi

    if [[ -z "$newest" ]] || [[ "$candidate" -nt "$newest" ]] || \
      [[ ! "$newest" -nt "$candidate" && "$candidate" > "$newest" ]]; then
      newest="$candidate"
    fi
  done < <(find "$downloads_dir" -maxdepth 1 -type f -name 'client_secret_*.json' -print0 2>/dev/null)

  if [[ -n "$newest" ]]; then
    printf '%s\n' "$newest"
  fi
}

gmail_mcp_authorization_is_current() {
  local token_path="$1"

  [[ -f "$token_path" ]] && jq -e \
    --arg required_scope "$GMAIL_MCP_SCOPES_REQUIRED" \
    '.scopes == [$required_scope]' \
    "$token_path" >/dev/null 2>&1
}

google_drive_mcp_authorizations_are_current() {
  local token_path="$1"

  [[ -f "$token_path" ]] && jq -e \
    --arg required_aliases "$GOOGLE_DRIVE_MCP_SCOPES_REQUIRED" \
    '
      def required_scope_urls:
        ($required_aliases | split(",") | map(
          if . == "drive" then "https://www.googleapis.com/auth/drive"
          elif . == "documents" then "https://www.googleapis.com/auth/documents"
          elif . == "spreadsheets" then "https://www.googleapis.com/auth/spreadsheets"
          else error("Unsupported required Google Drive scope alias: " + .)
          end
        )) + ["openid", "https://www.googleapis.com/auth/userinfo.email"]
        | unique | sort;
      .version == 2 and
      (.accounts | type) == "object" and
      (.accounts | length) > 0 and
      all(.accounts[];
        ((.scope // "") | split(" ") | map(select(length > 0)) | unique | sort)
          == required_scope_urls
      )
    ' \
    "$token_path" >/dev/null 2>&1
}

google_drive_mcp_account_aliases() {
  local token_path="$1"

  if [[ -f "$token_path" ]]; then
    jq -r \
      'if .version == 2 and (.accounts | type) == "object" then .accounts | keys[] else empty end' \
      "$token_path" 2>/dev/null || true
  fi
}

role_opencode_config_content() {
  local role="${1:-coder}"
  if [[ "$role" == "bureaucrat" ]]; then
    jq -c \
      --arg profile_root "$PROFILE_ROOT" \
      --arg model_id "$MODEL_ID" \
      --arg model_name "$MODEL_DISPLAY_NAME" \
      --arg google_drive_scopes "$GOOGLE_DRIVE_MCP_SCOPES_REQUIRED" \
      --argjson context "$CONTEXT_LENGTH" \
      --argjson output "$OUTPUT_LIMIT" \
      --argjson buffer "$COMPACTION_BUFFER" \
      '
        .policies = [{action: "provider.use", resource: "*", effect: "deny"},
                     {action: "provider.use", resource: "lmstudio", effect: "allow"}] |
        .default_agent = "qwen-bureaucrat" |
        .providers.lmstudio.models["qwen3.8-27b"].modelID = $model_id |
        .providers.lmstudio.models["qwen3.8-27b"].name = $model_name |
        .providers.lmstudio.models["qwen3.8-27b"].limit.context = $context |
        .providers.lmstudio.models["qwen3.8-27b"].limit.output = $output |
        .compaction.buffer = $buffer |
        .agents = {
          "qwen-bureaucrat": (.agents["qwen-bureaucrat"] + {system: ("{file:" + $profile_root + "/prompts/qwen-bureaucrat.txt}")}),
          "title": .agents.title, "compaction": .agents.compaction
        } |
        .mcp.servers = {
          "gmail": {
            "type": "local",
            "command": [
              "node",
              ($profile_root + "/scripts/mcp-gmail.mjs")
            ],
            "disabled": false,
            "codemode": false
          },
          "google_drive": {
            "type": "local",
            "command": [
              "node",
              ($profile_root + "/scripts/mcp-google-drive.mjs")
            ],
            "environment": {
              "GOOGLE_DRIVE_MCP_SCOPES": $google_drive_scopes
            },
            "disabled": false,
            "codemode": false
          },
          "chrome": {
            "type": "local",
            "command": [
              "npx",
              "-y",
              "chrome-devtools-mcp@latest",
              "--autoConnect",
              "--slim"
            ],
            "disabled": false,
            "codemode": false
          }
        } |
        .plugins = [
          ($profile_root + "/plugins/bureaucrat")
        ]
      ' "$PROFILE_ROOT/configs/bureaucrat.jsonc"
  else
    jq -c \
      --arg profile_root "$PROFILE_ROOT" \
      --arg model_id "$MODEL_ID" \
      --arg model_name "$MODEL_DISPLAY_NAME" \
      --argjson context "$CONTEXT_LENGTH" \
      --argjson output "$OUTPUT_LIMIT" \
      --argjson buffer "$COMPACTION_BUFFER" \
      '
        .providers.lmstudio.models["qwen3.8-27b"].modelID = $model_id |
        .providers.lmstudio.models["qwen3.8-27b"].name = $model_name |
        .providers.lmstudio.models["qwen3.8-27b"].limit.context = $context |
        .providers.lmstudio.models["qwen3.8-27b"].limit.output = $output |
        .compaction.buffer = $buffer |
        .policies = [{action: "provider.use", resource: "*", effect: "deny"},
                     {action: "provider.use", resource: "lmstudio", effect: "allow"}] |
        .default_agent = "qwen-local" |
        .agents = {
          "qwen-local": (.agents["qwen-local"] + {system: ("{file:" + $profile_root + "/prompts/qwen-local.txt}")}),
          "title": .agents.title, "compaction": .agents.compaction
        } |
        .mcp.servers = {
          "context7": .mcp.servers.context7,
          "gh_grep": .mcp.servers.gh_grep
        } |
        .plugins = [
          ($profile_root + "/plugins/coder")
        ]
      ' "$PROFILE_ROOT/configs/coder.jsonc"
  fi
}

runtime_opencode_config_content() {
  if [[ "$INFERENCE_BACKEND" == "splash" ]]; then
    role_opencode_config_content "$@" | splash_config_content
  else
    role_opencode_config_content "$@"
  fi
}

configure_opencode_environment() {
  local role="${1:-coder}"
  if [[ "$role" == "bureaucrat" ]]; then
    export OPENCODE_CONFIG="$PROFILE_ROOT/configs/bureaucrat.jsonc"
    export OPENCODE_CONFIG_DIR="$PROFILE_ROOT/.opencode-bureaucrat"
    export GOOGLE_DRIVE_MCP_SCOPES="$GOOGLE_DRIVE_MCP_SCOPES_REQUIRED"
  else
    export OPENCODE_CONFIG="$PROFILE_ROOT/configs/coder.jsonc"
    export OPENCODE_CONFIG_DIR="$PROFILE_ROOT/.opencode-coder"
  fi
  export OPENCODE_CONFIG_CONTENT
  OPENCODE_CONFIG_CONTENT="$(runtime_opencode_config_content "$role")" || return
  export OPENCODE_DISABLE_CLAUDE_CODE_SKILLS=true
}

resolved_opencode_config() {
  "$OPENCODE_BIN" debug config --standalone | jq -e '
    def selection:
      .providerID + "/" + .model + (if .variant then "#" + .variant else "" end);
    reduce (.[] | select(.type == "document") | .info) as $info ({}; . * $info) |
    .model |= selection |
    .agents |= with_entries(if .value.model then .value.model |= selection else . end)
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
    if [[ " $command " == *" --standalone "* || \
      " $command " == *" --model $OPENCODE_MODEL "* || \
      " $command " == *" --model $OPENCODE_MODEL#"* ]]; then
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
