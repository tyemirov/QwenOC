#!/bin/bash

set -u
set -o pipefail

PROFILE_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$PROFILE_DIR/scripts/profile.sh"

usage() {
  printf 'Usage: %s [--backend local|splash] [--require-live] [project-directory]\n' "$0"
  printf 'Checks the host, installed model, OpenCode profiles, and MCP connections without changing runtime state.\n'
  printf 'Use --require-live to require the selected local model server.\n'
}

REQUIRE_LIVE=0
PROJECT_DIR=""
while (( $# > 0 )); do
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    --backend)
      if (( $# < 2 )); then
        printf 'The --backend option requires local or splash.\n' >&2
        exit 2
      fi
      INFERENCE_BACKEND="$2"
      shift
      ;;
    --backend=*)
      INFERENCE_BACKEND="${1#*=}"
      ;;
    --require-live)
      REQUIRE_LIVE=1
      ;;
    --)
      shift
      if (( $# > 1 )) || { (( $# == 1 )) && [[ -n "$PROJECT_DIR" ]]; }; then
        printf 'Only one project directory may be specified.\n' >&2
        usage >&2
        exit 2
      fi
      PROJECT_DIR="${1:-$PROJECT_DIR}"
      break
      ;;
    -*)
      printf 'Unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ -n "$PROJECT_DIR" ]]; then
        printf 'Only one project directory may be specified.\n' >&2
        usage >&2
        exit 2
      fi
      PROJECT_DIR="$1"
      ;;
  esac
  shift
done

PROJECT_DIR="${PROJECT_DIR:-$PROFILE_DIR}"
case "$PROJECT_DIR" in
  "~") PROJECT_DIR="$HOME" ;;
  "~/"*) PROJECT_DIR="$HOME/${PROJECT_DIR#\~/}" ;;
esac

FAILURES=0

pass() {
  printf 'PASS  %s\n' "$1"
}

fail() {
  printf 'FAIL  %s\n' "$1" >&2
  FAILURES=$((FAILURES + 1))
}

info() {
  printf 'INFO  %s\n' "$1"
}

mcp_server_is_connected() {
  local server_name="$1"
  local status_output="$2"

  awk -v server_name="$server_name" '
    {
      for (field = 1; field < NF; field++) {
        if ($field == server_name && $(field + 1) == "connected") {
          found = 1
        }
      }
    }
    END { exit(found ? 0 : 1) }
  ' <<<"$status_output"
}

initialize_inference_backend "$INFERENCE_BACKEND" || exit $?

if [[ "$INFERENCE_BACKEND" == "splash" ]]; then
  OPENCODE_BIN="$(resolve_opencode_bin)"
  if [[ -z "$OPENCODE_BIN" ]]; then
    fail "OpenCode was not found in PATH"
  elif ! version_at_least "$("$OPENCODE_BIN" --version)" "$MIN_OPENCODE_VERSION"; then
    fail "OpenCode $MIN_OPENCODE_VERSION or newer is required"
  fi
  if [[ ! -d "$PROJECT_DIR" ]]; then
    fail "Target project does not exist: $PROJECT_DIR"
  fi
  if splash_is_listening; then
    if read_splash_runtime; then
      pass "Splash serves $MODEL_ID with a $CONTEXT_LENGTH-token context"
    else
      fail "Splash runtime does not match the selected profile"
    fi
  elif [[ "$REQUIRE_LIVE" -eq 1 ]]; then
    fail "Splash is not running at $SPLASH_URL"
  elif command -v splash >/dev/null 2>&1; then
    info "Splash is stopped; live checks skipped"
  else
    fail "Splash was not found; run install.command --backend splash"
  fi
  if (( FAILURES == 0 )); then
    for role in coder bureaucrat; do
      configure_opencode_environment "$role" || exit $?
      if RESOLVED_CONFIG="$(cd "$PROJECT_DIR" && "$OPENCODE_BIN" debug config)" &&
        jq -e --arg model "$OPENCODE_MODEL" --arg id "$MODEL_ID" \
          --arg url "$SPLASH_URL/v1" --argjson context "$CONTEXT_LENGTH" \
          --argjson output "$OUTPUT_LIMIT" '
          .model == $model and .small_model == $model and
          .enabled_providers == ["splash"] and
          ((.disabled_providers // []) | index("splash")) == null and
          .agent[.default_agent].model == $model and
          .provider.splash.npm == "@ai-sdk/openai-compatible" and
          .provider.splash.options.baseURL == $url and
          .provider.splash.models[$id].limit.context == $context and
          .provider.splash.models[$id].limit.output == $output and
          .provider.splash.models[$id].options.reasoningEffort == "medium" and
          .compaction.reserved == $output
        ' <<<"$RESOLVED_CONFIG" >/dev/null; then
        pass "Resolved Splash $role configuration"
      else
        fail "Resolved Splash $role configuration conflicts with this profile"
      fi
    done
  fi
  if (( FAILURES > 0 )); then
    printf '\nDoctor found %d failure(s).\n' "$FAILURES" >&2
    exit 1
  fi
  printf '\nReady: Splash configuration checks passed.\n'
  exit 0
fi

if [[ "$(uname -s)" == "Darwin" && "$(uname -m)" == "arm64" ]]; then
  pass "Apple Silicon macOS host"
else
  fail "This profile requires an Apple Silicon Mac"
fi

if validate_model_tier_map; then
  pass "Adaptive model tier map is valid"
else
  fail "Adaptive model tier map is invalid: $MODEL_TIER_MAP"
fi

MEMORY_GIB="$DETECTED_MEMORY_GIB"
if [[ "$HARDWARE_PROFILE_SUPPORTED" -eq 1 ]]; then
  pass "${MEMORY_GIB} GiB selects the ${PROFILE_TIER} profile: ${MODEL_QUANTIZATION}, ${CONTEXT_LENGTH}-token context"
else
  fail "${MEMORY_GIB:-unknown} GiB physical memory; ${MIN_SUPPORTED_MEMORY_GIB} GiB is required"
fi

for required_command in curl jq git; do
  if command -v "$required_command" >/dev/null 2>&1; then
    pass "$required_command is available"
  else
    fail "$required_command is required"
  fi
done

if command -v npx >/dev/null 2>&1; then
  pass "Node.js / npx is available (required for MCP servers)"
else
  fail "Node.js / npx is required for Google Workspace MCP (brew install node)"
fi

CHROME_VERSION="$(chrome_version)"
if chrome_supports_auto_connect; then
  pass "Chrome $CHROME_VERSION supports existing-session auto-connect"
else
  fail "Chrome $CHROME_MIN_AUTO_CONNECT_VERSION or newer is required for existing-session auto-connect"
fi
if chrome_auto_connect_is_ready; then
  pass "Running Chrome has Remote Debugging enabled for auto-connect"
else
  fail "Launch Chrome normally and enable Remote Debugging at chrome://inspect/#remote-debugging"
fi

if [[ -f "$PROFILE_DIR/prompts/qwen-local.txt" && -f "$PROFILE_DIR/prompts/qwen-bureaucrat.txt" ]]; then
  pass "Role prompts verified (qwen-local.txt & qwen-bureaucrat.txt)"
else
  fail "Missing prompt files under $PROFILE_DIR/prompts/"
fi



LMS_BIN="$(resolve_lms_bin)"
if [[ -n "$LMS_BIN" ]]; then
  pass "LM Studio CLI: $LMS_BIN"
  if "$LMS_BIN" load --help 2>&1 | grep -Fq -- '--speculative-draft-mtp'; then
    pass "LM Studio CLI supports bundled MTP loading"
  else
    fail "LM Studio must be updated to a version with --speculative-draft-mtp"
  fi
else
  fail "LM Studio CLI was not found"
fi

OPENCODE_BIN="$(resolve_opencode_bin)"
if [[ -n "$OPENCODE_BIN" ]]; then
  OPENCODE_VERSION="$($OPENCODE_BIN --version 2>/dev/null | tail -1)"
  if version_at_least "$OPENCODE_VERSION" "$MIN_OPENCODE_VERSION"; then
    pass "OpenCode $OPENCODE_VERSION (minimum $MIN_OPENCODE_VERSION)"
  else
    fail "OpenCode $OPENCODE_VERSION is older than $MIN_OPENCODE_VERSION"
  fi
else
  fail "OpenCode was not found"
fi

if [[ -d "$PROJECT_DIR" ]]; then
  PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"
  pass "Target project exists: $PROJECT_DIR"
else
  fail "Target project does not exist: $PROJECT_DIR"
fi

ACTIVE_SESSION_COUNT="$(active_opencode_session_count)"
if (( ACTIVE_SESSION_COUNT <= 1 )); then
  pass "Single-session runtime (${ACTIVE_SESSION_COUNT} active)"
else
  fail "${ACTIVE_SESSION_COUNT} OpenCode sessions are competing for the one-slot local model"
fi

if command -v jq >/dev/null 2>&1 && [[ -n "$LMS_BIN" ]]; then
  if model_is_installed; then
    pass "Exact model is installed: $MODEL_VARIANT_KEY"
  else
    fail "Exact model is missing: $MODEL_VARIANT_KEY"
  fi

  if model_is_selected; then
    pass "LM Studio selected GGUF $MODEL_QUANTIZATION as the active source"
  else
    fail "Select $MODEL_QUANTIZATION MTP GGUF under LM Studio > My Models > Qwen3.8 27B > Variants"
  fi

  if server_is_ready; then
    pass "LM Studio API is reachable at $LMSTUDIO_URL"
    LIVE_CONTEXT="$(loaded_context)"
    if [[ "$LIVE_CONTEXT" == "$CONTEXT_LENGTH" ]] && loaded_is_required_variant; then
      pass "Live model uses ${MODEL_QUANTIZATION}, ${CONTEXT_LENGTH}-token context, Flash Attention, and MTP"
    elif [[ -z "$LIVE_CONTEXT" && "$REQUIRE_LIVE" -eq 0 ]]; then
      info "The dedicated model is not loaded; launchers load exact ${MODEL_QUANTIZATION} + MTP on start"
    elif [[ -z "$LIVE_CONTEXT" ]]; then
      fail "The dedicated ${MODEL_QUANTIZATION} + MTP model is not loaded"
    else
      fail "The live model does not match the required ${MODEL_QUANTIZATION} + MTP load configuration"
    fi
  elif [[ "$REQUIRE_LIVE" -eq 1 ]]; then
    fail "LM Studio API is not running at $LMSTUDIO_URL"
  else
    info "LM Studio API is not running; live model checks skipped (use --require-live to require them)"
  fi
fi

if command -v jq >/dev/null 2>&1 && [[ -n "$OPENCODE_BIN" && -d "$PROJECT_DIR" ]]; then
  # 1. Verify Coder Profile Contract
  CODER_CONFIG_CONTENT="$(runtime_opencode_config_content coder 2>/dev/null || true)"
  RESOLVED_CODER_CONFIG="$(
    cd "$PROJECT_DIR" &&
      OPENCODE_CONFIG="$PROFILE_DIR/configs/coder.jsonc" \
      OPENCODE_CONFIG_DIR="$PROFILE_DIR/.opencode-coder" \
      OPENCODE_CONFIG_CONTENT="$CODER_CONFIG_CONTENT" \
      OPENCODE_EXPERIMENTAL_LSP_TOOL=true \
      OPENCODE_ENABLE_EXA=true \
      OPENCODE_DISABLE_CLAUDE_CODE_SKILLS=true \
      "$OPENCODE_BIN" debug config 2>/dev/null
  )"
  if jq -e \
    --arg model_id "$MODEL_ID" \
    --argjson context "$CONTEXT_LENGTH" \
    --argjson output "$OUTPUT_LIMIT" \
    --argjson reserved "$COMPACTION_RESERVED" \
    '.model == "lmstudio/qwen3.8-27b" and
     .default_agent == "qwen-local" and
     .provider.lmstudio.models["qwen3.8-27b"].id == $model_id and
     .provider.lmstudio.models["qwen3.8-27b"].limit.context == $context and
     .provider.lmstudio.models["qwen3.8-27b"].limit.output == $output and
     .provider.lmstudio.options.timeout == 1800000 and
     (.provider.lmstudio.options | has("chunkTimeout") | not) and
     .agent["qwen-local"].variant == "medium" and
     .compaction.auto == true and
     .compaction.prune == true and
     .compaction.reserved == $reserved and
     .mcp.context7.enabled == true and
     .mcp.gh_grep.enabled == true and
     (.mcp | has("google_workspace") | not)' \
    <<<"$RESOLVED_CODER_CONFIG" >/dev/null 2>&1; then
    pass "Resolved Coder profile preserves dedicated coding MCPs (context7, gh_grep)"
  else
    fail "Coder profile resolution failed"
  fi

  # 2. Verify Bureaucrat Profile Contract
  BUREAUCRAT_CONFIG_CONTENT="$(runtime_opencode_config_content bureaucrat 2>/dev/null || true)"
  RESOLVED_BUREAUCRAT_CONFIG="$(
    cd "$PROJECT_DIR" &&
      OPENCODE_CONFIG="$PROFILE_DIR/configs/bureaucrat.jsonc" \
      OPENCODE_CONFIG_DIR="$PROFILE_DIR/.opencode-bureaucrat" \
      OPENCODE_CONFIG_CONTENT="$BUREAUCRAT_CONFIG_CONTENT" \
      OPENCODE_ENABLE_EXA=true \
      OPENCODE_DISABLE_CLAUDE_CODE_SKILLS=true \
      "$OPENCODE_BIN" debug config 2>/dev/null
  )"
  if jq -e \
    --arg model_id "$MODEL_ID" \
    --argjson context "$CONTEXT_LENGTH" \
    --argjson output "$OUTPUT_LIMIT" \
    --argjson reserved "$COMPACTION_RESERVED" \
    '.model == "lmstudio/qwen3.8-27b" and
     .default_agent == "qwen-bureaucrat" and
     .provider.lmstudio.models["qwen3.8-27b"].id == $model_id and
     .provider.lmstudio.models["qwen3.8-27b"].limit.context == $context and
     .provider.lmstudio.models["qwen3.8-27b"].limit.output == $output and
     .agent["qwen-bureaucrat"].variant == "low" and
     .compaction.auto == true and
     .compaction.prune == true and
     .compaction.reserved == $reserved and
     .mcp.gmail.enabled == true and
     .mcp.google_drive.enabled == true and
     .mcp.google_drive.environment.GOOGLE_DRIVE_MCP_SCOPES == "drive,documents,spreadsheets" and
     .mcp.chrome.enabled == true and
     (.mcp.chrome.command | index("--browserUrl")) == null and
     (.mcp.chrome.command | index("--autoConnect")) != null and
     .agent["qwen-bureaucrat"].tools.gmail_send_draft == true and
     .agent["qwen-bureaucrat"].tools.gmail_delete_draft == true and
     .agent["qwen-bureaucrat"].tools.google_drive_authGetStatus == true and
     .agent["qwen-bureaucrat"].tools.google_drive_manage_accounts == true and
     .agent["qwen-bureaucrat"].permission.gmail_download_attachment == "deny" and
     .agent["qwen-bureaucrat"].permission["gmail_send_*"] == "ask" and
     .agent["qwen-bureaucrat"].permission["gmail_delete_*"] == "ask" and
     .agent["qwen-bureaucrat"].permission["google_drive_delete_*"] == "ask"' \
    <<<"$RESOLVED_BUREAUCRAT_CONFIG" >/dev/null 2>&1; then
    pass "Resolved Bureaucrat profile preserves dedicated office MCPs (gmail, google_drive, chrome)"
  else
    fail "Bureaucrat profile resolution failed"
  fi

  GMAIL_TOKENS="$HOME/.gmail-mcp/credentials.json"
  DRIVE_TOKENS="$HOME/.config/google-drive-mcp/tokens.json"
  if [[ ! -f "$GMAIL_TOKENS" && ! -f "$DRIVE_TOKENS" ]]; then
    info "Bureaucrat Google authorizations are not configured"
  else
    if gmail_mcp_authorization_is_current "$GMAIL_TOKENS"; then
      pass "Gmail authorization matches the required scope contract ($GMAIL_MCP_SCOPES_REQUIRED)"
    else
      fail "Gmail authorization needs scoped re-consent (launch-bureaucrat.command --reauthorize gmail)"
    fi

    if google_drive_mcp_authorizations_are_current "$DRIVE_TOKENS"; then
      pass "Every Drive authorization matches the required data-scope contract ($GOOGLE_DRIVE_MCP_SCOPES_REQUIRED)"
    else
      fail "Drive authorization needs scoped re-consent (launch-bureaucrat.command --reauthorize drive)"
    fi
  fi

  # 3. Verify Live MCP Connections for Coder
  CODER_MCP_OUTPUT="$(
    cd "$PROJECT_DIR" &&
      OPENCODE_CONFIG="$PROFILE_DIR/configs/coder.jsonc" \
      OPENCODE_CONFIG_DIR="$PROFILE_DIR/.opencode-coder" \
      OPENCODE_CONFIG_CONTENT="$CODER_CONFIG_CONTENT" \
      OPENCODE_DISABLE_CLAUDE_CODE_SKILLS=true \
      "$OPENCODE_BIN" mcp list 2>/dev/null
  )"
  CODER_MCP_PLAIN="$(printf '%s\n' "$CODER_MCP_OUTPUT" | sed $'s/\033\\[[0-9;]*m//g')"
  if mcp_server_is_connected context7 "$CODER_MCP_PLAIN" && \
    mcp_server_is_connected gh_grep "$CODER_MCP_PLAIN"; then
    pass "Coder MCP servers are connected (context7, gh_grep)"
  else
    fail "Coder MCP servers (context7, gh_grep) failed to connect"
  fi

  # 4. Verify Live MCP Connections for Bureaucrat
  BUREAUCRAT_MCP_OUTPUT="$(
    cd "$PROJECT_DIR" &&
      OPENCODE_CONFIG="$PROFILE_DIR/configs/bureaucrat.jsonc" \
      OPENCODE_CONFIG_DIR="$PROFILE_DIR/.opencode-bureaucrat" \
      OPENCODE_CONFIG_CONTENT="$BUREAUCRAT_CONFIG_CONTENT" \
      OPENCODE_DISABLE_CLAUDE_CODE_SKILLS=true \
      "$OPENCODE_BIN" mcp list 2>/dev/null
  )"
  BUREAUCRAT_MCP_PLAIN="$(printf '%s\n' "$BUREAUCRAT_MCP_OUTPUT" | sed $'s/\033\\[[0-9;]*m//g')"
  if mcp_server_is_connected gmail "$BUREAUCRAT_MCP_PLAIN" && \
    mcp_server_is_connected google_drive "$BUREAUCRAT_MCP_PLAIN" && \
    mcp_server_is_connected chrome "$BUREAUCRAT_MCP_PLAIN"; then
    pass "Bureaucrat MCP transports initialized (gmail, google_drive, chrome)"
  else
    fail "Bureaucrat MCP transports (gmail, google_drive, chrome) failed to initialize"
  fi
fi

info "Tested with LM Studio $TESTED_LM_STUDIO_VERSION, llama.cpp runtime $TESTED_LLAMA_RUNTIME_VERSION, and OpenCode $TESTED_OPENCODE_VERSION"

if (( FAILURES > 0 )); then
  printf '\nDoctor found %d failure(s).\n' "$FAILURES" >&2
  exit 1
fi

if [[ "$REQUIRE_LIVE" -eq 1 ]]; then
  printf '\nReady: OpenCode is connected to Qwen 3.8 27B GGUF %s with bundled MTP.\n' \
    "$MODEL_QUANTIZATION"
else
  printf '\nReady: QwenOC installation and configuration checks passed.\n'
fi
