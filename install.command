#!/bin/bash

set -euo pipefail

PROFILE_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$PROFILE_DIR/scripts/profile.sh"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  printf 'Usage: %s\n' "$0"
  printf 'Detects memory, installs prerequisites, downloads the mapped Qwen quantization, loads MTP, and runs diagnostics.\n'
  exit 0
fi

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
  printf 'This profile requires an Apple Silicon Mac.\n' >&2
  exit 2
fi

MEMORY_GIB="$DETECTED_MEMORY_GIB"
if [[ "$HARDWARE_PROFILE_SUPPORTED" -ne 1 ]]; then
  printf 'QwenOC requires at least %s GiB of physical memory; detected %s GiB.\n' \
    "$MIN_SUPPORTED_MEMORY_GIB" "${MEMORY_GIB:-unknown}" >&2
  exit 2
fi
printf 'Selected %s profile for %s GiB: %s, %s-token context.\n' \
  "$PROFILE_TIER" "$MEMORY_GIB" "$MODEL_QUANTIZATION" "$CONTEXT_LENGTH"

BREW_BIN="$(command -v brew || true)"
if [[ -z "$BREW_BIN" ]]; then
  printf 'Homebrew is required for automatic prerequisite installation: https://brew.sh\n' >&2
  exit 3
fi

if [[ ! -d '/Applications/LM Studio.app' ]]; then
  printf 'Installing LM Studio...\n'
  "$BREW_BIN" install --cask lm-studio
fi

LMS_BIN="$(resolve_lms_bin)"
if [[ -z "$LMS_BIN" ]]; then
  printf 'Opening LM Studio once to initialize its CLI...\n'
  open -gj -a 'LM Studio'
  for _attempt in {1..30}; do
    LMS_BIN="$(resolve_lms_bin)"
    [[ -n "$LMS_BIN" ]] && break
    sleep 1
  done
fi
if [[ -z "$LMS_BIN" ]]; then
  printf 'LM Studio did not initialize %s/.lmstudio/bin/lms within 30 seconds. Open LM Studio once, then rerun this installer.\n' "$HOME" >&2
  exit 3
fi

if ! "$LMS_BIN" load --help 2>&1 | grep -Fq -- '--speculative-draft-mtp'; then
  printf 'LM Studio must be updated to a version that supports --speculative-draft-mtp.\n' >&2
  exit 3
fi

if ! command -v jq >/dev/null 2>&1; then
  printf 'Installing jq...\n'
  "$BREW_BIN" install jq
fi

OPENCODE_BIN="$(resolve_opencode_bin)"
if [[ -z "$OPENCODE_BIN" ]]; then
  printf 'Installing OpenCode...\n'
  "$BREW_BIN" install anomalyco/tap/opencode
  OPENCODE_BIN="$(resolve_opencode_bin)"
fi
if [[ -z "$OPENCODE_BIN" ]]; then
  printf 'OpenCode installation completed but its executable is not in PATH. Open a new terminal and rerun this installer.\n' >&2
  exit 3
fi

OPENCODE_VERSION="$($OPENCODE_BIN --version 2>/dev/null | tail -1)"
if ! version_at_least "$OPENCODE_VERSION" "$MIN_OPENCODE_VERSION"; then
  printf 'OpenCode %s or newer is required; detected %s.\n' "$MIN_OPENCODE_VERSION" "$OPENCODE_VERSION" >&2
  exit 3
fi

if ! model_is_installed; then
  FREE_GIB="$(df -Pk "$HOME" | awk 'NR == 2 {printf "%.0f\n", $4 / 1048576}')"
  if [[ ! "$FREE_GIB" =~ ^[0-9]+$ ]] || (( FREE_GIB < MODEL_DOWNLOAD_MIN_FREE_GIB )); then
    printf 'The %s model download requires at least %s GiB free; detected %s GiB.\n' \
      "$MODEL_QUANTIZATION" "$MODEL_DOWNLOAD_MIN_FREE_GIB" "${FREE_GIB:-unknown}" >&2
    exit 4
  fi
  printf 'Downloading Qwen 3.8 27B GGUF %s with its bundled MTP head (model file about %s GiB)...\n' \
    "$MODEL_QUANTIZATION" "$MODEL_SIZE_GIB"
  "$LMS_BIN" get "$MODEL_VARIANT_KEY" --gguf --yes
else
  printf 'Exact model is already installed: %s\n' "$MODEL_VARIANT_KEY"
fi

if ! model_is_selected; then
  printf 'LM Studio must select the downloaded %s source before setup can continue.\n' "$MODEL_QUANTIZATION" >&2
  printf 'Open LM Studio > My Models > Qwen3.8 27B > Variants and select %s MTP GGUF, then rerun this installer.\n' \
    "$MODEL_QUANTIZATION" >&2
  open -a 'LM Studio'
  exit 4
fi

if ! server_is_ready; then
  printf 'Starting the LM Studio API server...\n'
  "$LMS_BIN" server start >/dev/null
  for _attempt in {1..30}; do
    server_is_ready && break
    sleep 1
  done
fi
if ! server_is_ready; then
  printf 'LM Studio did not start its API server at %s.\n' "$LMSTUDIO_URL" >&2
  exit 5
fi

CURRENT_CONTEXT="$(loaded_context)"
if [[ -n "$CURRENT_CONTEXT" ]] && \
  { [[ "$CURRENT_CONTEXT" != "$CONTEXT_LENGTH" ]] || ! loaded_is_required_variant; }; then
  if [[ "$(loaded_status)" != "idle" ]]; then
    printf 'The dedicated Qwen instance is active with a different load configuration. Let its request finish, then rerun this installer.\n' >&2
    exit 5
  fi
  printf 'Reloading the dedicated Qwen instance with the canonical MTP configuration...\n'
  "$LMS_BIN" unload "$MODEL_ID" >/dev/null
  CURRENT_CONTEXT=""
fi

if [[ -z "$CURRENT_CONTEXT" ]]; then
  printf 'Loading Qwen 3.8 27B %s with MTP and a %s-token context...\n' \
    "$MODEL_QUANTIZATION" "$CONTEXT_LENGTH"
  "$LMS_BIN" load "$MODEL_BASE_KEY" \
    --identifier "$MODEL_ID" \
    --context-length "$CONTEXT_LENGTH" \
    --gpu max \
    --parallel 1 \
    --speculative-draft-mtp \
    --yes
fi

"$PROFILE_DIR/doctor.command" "$PROFILE_DIR"

printf '\nInstallation complete. Launch with:\n  %s/launch-opencode.command [project-directory]\n' "$PROFILE_DIR"
