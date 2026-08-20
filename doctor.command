#!/bin/bash

set -u
set -o pipefail

PROFILE_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$PROFILE_DIR/scripts/profile.sh"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  printf 'Usage: %s [project-directory]\n' "$0"
  printf 'Checks the host, exact model, live MTP configuration, OpenCode profile, and MCP connections.\n'
  exit 0
fi

PROJECT_DIR="${1:-$PROFILE_DIR}"
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
    if [[ "$(loaded_context)" == "$CONTEXT_LENGTH" ]] && loaded_is_required_variant; then
      pass "Live model uses ${MODEL_QUANTIZATION}, ${CONTEXT_LENGTH}-token context, Flash Attention, and MTP"
    else
      fail "The live model does not match the required ${MODEL_QUANTIZATION} + MTP load configuration"
    fi
  else
    fail "LM Studio API is not running at $LMSTUDIO_URL"
  fi
fi

if command -v jq >/dev/null 2>&1 && [[ -n "$OPENCODE_BIN" && -d "$PROJECT_DIR" ]]; then
  RUNTIME_CONFIG_CONTENT="$(runtime_opencode_config_content 2>/dev/null || true)"
  RESOLVED_CONFIG="$(
    cd "$PROJECT_DIR" &&
      OPENCODE_CONFIG="$PROFILE_DIR/opencode.jsonc" \
      OPENCODE_CONFIG_DIR="$PROFILE_DIR/.opencode" \
      OPENCODE_CONFIG_CONTENT="$RUNTIME_CONFIG_CONTENT" \
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
     .mcp.gh_grep.enabled == true' \
    <<<"$RESOLVED_CONFIG" >/dev/null 2>&1; then
    pass "Resolved OpenCode profile preserves the model, agent, compaction, and MCP contract"
  else
    fail "The target project's resolved OpenCode configuration overrides the required profile"
  fi

  MCP_OUTPUT="$(
    cd "$PROJECT_DIR" &&
      OPENCODE_CONFIG="$PROFILE_DIR/opencode.jsonc" \
      OPENCODE_CONFIG_DIR="$PROFILE_DIR/.opencode" \
      OPENCODE_CONFIG_CONTENT="$RUNTIME_CONFIG_CONTENT" \
      OPENCODE_DISABLE_CLAUDE_CODE_SKILLS=true \
      "$OPENCODE_BIN" mcp list 2>/dev/null
  )"
  MCP_OUTPUT_PLAIN="$(printf '%s\n' "$MCP_OUTPUT" | sed $'s/\033\\[[0-9;]*m//g')"
  CONNECTED_COUNT="$(printf '%s\n' "$MCP_OUTPUT_PLAIN" | grep -c 'connected' || true)"
  if grep -Fq 'context7' <<<"$MCP_OUTPUT_PLAIN" && \
    grep -Fq 'gh_grep' <<<"$MCP_OUTPUT_PLAIN" && \
    (( CONNECTED_COUNT >= 2 )); then
    pass "Context7 and gh_grep MCP servers are connected"
  else
    fail "Context7 and gh_grep must both be connected"
  fi
fi

info "Tested with LM Studio $TESTED_LM_STUDIO_VERSION, llama.cpp runtime $TESTED_LLAMA_RUNTIME_VERSION, and OpenCode $TESTED_OPENCODE_VERSION"

if (( FAILURES > 0 )); then
  printf '\nDoctor found %d failure(s).\n' "$FAILURES" >&2
  exit 1
fi

printf '\nReady: OpenCode is connected to Qwen 3.8 27B GGUF %s with bundled MTP.\n' \
  "$MODEL_QUANTIZATION"
