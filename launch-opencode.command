#!/bin/bash

set -euo pipefail

PROFILE_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$PROFILE_DIR/scripts/profile.sh"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  printf 'Usage: %s [project-directory] [-- OpenCode options]\n' "$0"
  printf '       %s --doctor [project-directory]\n' "$0"
  exit 0
fi

if [[ "${1:-}" == "--doctor" ]]; then
  shift
  exec "$PROFILE_DIR/doctor.command" "$@"
fi

if [[ "$HARDWARE_PROFILE_SUPPORTED" -ne 1 ]]; then
  printf 'QwenOC requires at least %s GiB of physical memory; detected %s GiB.\n' \
    "$MIN_SUPPORTED_MEMORY_GIB" "${DETECTED_MEMORY_GIB:-unknown}" >&2
  exit 2
fi

if [[ -n "${1:-}" && "${1:-}" != "--" ]]; then
  PROJECT_DIR="$1"
  shift
else
  CURRENT_REPO="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || true)"
  DEFAULT_PROJECT="${CURRENT_REPO:-$HOME/Documents/Projects}"
  if [[ -t 0 ]]; then
    printf 'Project folder [%s]: ' "$DEFAULT_PROJECT"
    read -r PROJECT_DIR
    PROJECT_DIR="${PROJECT_DIR:-$DEFAULT_PROJECT}"
  else
    PROJECT_DIR="$DEFAULT_PROJECT"
  fi
fi

if [[ "${1:-}" == "--" ]]; then
  shift
fi

case "$PROJECT_DIR" in
  "~") PROJECT_DIR="$HOME" ;;
  "~/"*) PROJECT_DIR="$HOME/${PROJECT_DIR#\~/}" ;;
esac

if [[ ! -d "$PROJECT_DIR" ]]; then
  printf 'Project folder does not exist: %s\n' "$PROJECT_DIR" >&2
  exit 2
fi
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"

LMS_BIN="$(resolve_lms_bin)"
OPENCODE_BIN="$(resolve_opencode_bin)"
if [[ ! -x "$LMS_BIN" ]]; then
  printf 'LM Studio CLI was not found. Open LM Studio and install its CLI integration.\n' >&2
  exit 3
fi
if [[ -z "$OPENCODE_BIN" || ! -x "$OPENCODE_BIN" ]]; then
  printf 'OpenCode was not found in PATH.\n' >&2
  exit 3
fi
if ! command -v jq >/dev/null 2>&1; then
  printf 'jq is required to verify LM Studio model state.\n' >&2
  exit 3
fi

ACTIVE_SESSION_PIDS="$(active_opencode_session_pids)"
if [[ -n "$ACTIVE_SESSION_PIDS" ]]; then
  printf 'The dedicated local model already has an OpenCode session (PID %s).\n' \
    "$(printf '%s\n' "$ACTIVE_SESSION_PIDS" | paste -sd, -)" >&2
  printf 'Continue in that session or close it before launching another.\n' >&2
  exit 7
fi
if ! acquire_session_lock; then
  printf 'Another launcher is already starting the dedicated OpenCode session.\n' >&2
  exit 7
fi
trap release_session_lock EXIT

if ! model_is_installed; then
  printf 'The %s profile requires an exact GGUF %s MTP model: %s\n' \
    "$PROFILE_TIER" "$MODEL_QUANTIZATION" "$MODEL_VARIANT_KEY" >&2
  printf 'Run %s/install.command to download it, then launch again.\n' "$PROFILE_DIR" >&2
  exit 4
fi

if ! model_is_selected; then
  printf 'LM Studio has not selected the mapped GGUF %s MTP source.\n' "$MODEL_QUANTIZATION" >&2
  printf 'In LM Studio, open My Models, choose Qwen3.8 27B > Variants, and select %s MTP GGUF.\n' \
    "$MODEL_QUANTIZATION" >&2
  exit 4
fi

if ! server_is_ready; then
  printf 'Starting the LM Studio API server...\n'
  "$LMS_BIN" server start >/dev/null
fi

SERVER_READY=0
for _attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
  if server_is_ready; then
    SERVER_READY=1
    break
  fi
  sleep 1
done
if [[ "$SERVER_READY" -ne 1 ]]; then
  printf 'LM Studio did not become ready at %s within 30 seconds.\n' "$LMSTUDIO_URL" >&2
  exit 5
fi

CURRENT_CONTEXT="$(loaded_context)"
if [[ -n "$CURRENT_CONTEXT" ]] && \
  { [[ "$CURRENT_CONTEXT" != "$CONTEXT_LENGTH" ]] || ! loaded_is_required_variant; }; then
  if [[ "$(loaded_status)" != "idle" ]]; then
    printf 'The dedicated Qwen instance is active with the wrong load configuration; close its active request and launch again.\n' >&2
    exit 6
  fi
  printf 'Reloading Qwen to enforce GGUF %s, MTP, and a %s-token context...\n' \
    "$MODEL_QUANTIZATION" "$CONTEXT_LENGTH"
  "$LMS_BIN" unload "$MODEL_ID" >/dev/null
  CURRENT_CONTEXT=""
fi

if [[ -z "$CURRENT_CONTEXT" ]]; then
  printf 'Loading Qwen 3.8 27B GGUF %s with MTP and a %s-token context...\n' \
    "$MODEL_QUANTIZATION" "$CONTEXT_LENGTH"
  "$LMS_BIN" load "$MODEL_BASE_KEY" \
    --identifier "$MODEL_ID" \
    --context-length "$CONTEXT_LENGTH" \
    --gpu max \
    --parallel 1 \
    --speculative-draft-mtp \
    --yes
fi

MODEL_READY=0
for _attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
  if [[ "$(loaded_context)" == "$CONTEXT_LENGTH" ]] && loaded_is_required_variant && \
    curl -fsS "$LMSTUDIO_URL/v1/models" | grep -Fq "$MODEL_ID"; then
    MODEL_READY=1
    break
  fi
  sleep 1
done
if [[ "$MODEL_READY" -ne 1 ]]; then
  printf 'Qwen 3.8 27B GGUF %s did not become available with MTP and the required context.\n' \
    "$MODEL_QUANTIZATION" >&2
  exit 6
fi

configure_opencode_environment

printf 'Opening OpenCode in %s with the %s %s profile (%s GiB detected).\n' \
  "$PROJECT_DIR" "$PROFILE_TIER" "$MODEL_QUANTIZATION" "$DETECTED_MEMORY_GIB"
cd "$PROJECT_DIR"
"$OPENCODE_BIN" "$PROJECT_DIR" \
  --model "lmstudio/qwen3.8-27b" \
  --agent "qwen-local" \
  "$@"
