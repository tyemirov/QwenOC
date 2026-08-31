#!/bin/bash

set -euo pipefail

PROFILE_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$PROFILE_DIR/scripts/profile.sh"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  printf 'Usage: %s [workspace-directory] [-- OpenCode options]\n' "$0"
  printf '       %s --doctor [--require-live] [workspace-directory]\n' "$0"
  printf '       %s --reauthorize [gmail|drive|all]\n' "$0"
  printf 'Launches Qwen The Bureaucrat (qwen-bureaucrat) for Gmail, Drive, and Sheets.\n'
  exit 0
fi

if [[ "${1:-}" == "--doctor" ]]; then
  shift
  exec "$PROFILE_DIR/doctor.command" "$@"
fi

REAUTHORIZE_TARGET=""
if [[ "${1:-}" == "--reauthorize" ]]; then
  shift
  REAUTHORIZE_TARGET="${1:-all}"
  case "$REAUTHORIZE_TARGET" in
    gmail|drive|all) ;;
    *)
      printf 'Unknown reauthorization target: %s\n' "$REAUTHORIZE_TARGET" >&2
      printf 'Choose gmail, drive, or all.\n' >&2
      exit 2
      ;;
  esac
  if [[ $# -gt 0 ]]; then
    shift
  fi
  if [[ $# -gt 0 ]]; then
    printf 'Reauthorization does not accept a workspace directory or OpenCode options.\n' >&2
    exit 2
  fi
fi

if [[ -z "$REAUTHORIZE_TARGET" && "$HARDWARE_PROFILE_SUPPORTED" -ne 1 ]]; then
  printf 'QwenOC requires at least %s GiB of physical memory; detected %s GiB.\n' \
    "$MIN_SUPPORTED_MEMORY_GIB" "${DETECTED_MEMORY_GIB:-unknown}" >&2
  exit 2
fi

# Determine target workspace directory
if [[ -z "$REAUTHORIZE_TARGET" ]]; then
  if [[ -n "${1:-}" && "${1:-}" != "--" ]]; then
    WORKSPACE_DIR="$1"
    shift
  else
    WORKSPACE_DIR="$HOME/Documents/OfficeWorkspace"
  fi

  if [[ "${1:-}" == "--" ]]; then
    shift
  fi

  case "$WORKSPACE_DIR" in
    "~") WORKSPACE_DIR="$HOME" ;;
    "~/"*) WORKSPACE_DIR="$HOME/${WORKSPACE_DIR#\~/}" ;;
  esac

  mkdir -p "$WORKSPACE_DIR"
  WORKSPACE_DIR="$(cd "$WORKSPACE_DIR" && pwd)"
fi

# Verify core dependencies
if [[ -z "$REAUTHORIZE_TARGET" ]]; then
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
fi
if ! command -v jq >/dev/null 2>&1; then
  printf 'jq is required to validate OAuth keys and LM Studio model state.\n' >&2
  exit 3
fi

# Verify Node.js / npx for Google Workspace MCP server
if ! command -v npx >/dev/null 2>&1; then
  printf 'ERROR: Node.js / npx was not found. Google Workspace MCP servers require Node.js.\n' >&2
  printf 'Install Node.js: brew install node\n' >&2
  exit 3
fi

if [[ -z "$REAUTHORIZE_TARGET" ]]; then
  if ! chrome_supports_auto_connect; then
    printf 'Chrome %s or newer is required to reuse an existing browser session.\n' \
      "$CHROME_MIN_AUTO_CONNECT_VERSION" >&2
    printf 'Install or update Google Chrome, then launch Bureaucrat again.\n' >&2
    exit 4
  fi
  if ! chrome_auto_connect_is_ready; then
    open -b "$CHROME_APPLICATION_ID" "chrome://inspect/#remote-debugging" 2>/dev/null || true
    printf 'Chrome is not ready for the Bureaucrat browser connection.\n' >&2
    printf 'In the Chrome page that opened, enable Remote Debugging, then launch Bureaucrat again.\n' >&2
    printf 'Chrome can otherwise be launched normally; no command-line flags are required.\n' >&2
    exit 4
  fi
fi

# Automatic gcloud Workspace API enablement (if gcloud is present and authenticated)
if command -v gcloud >/dev/null 2>&1; then
  GCLOUD_PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
  if [[ -n "$GCLOUD_PROJECT" ]]; then
    printf 'Checking Google Workspace APIs on project [%s]...\n' "$GCLOUD_PROJECT"
    gcloud services enable \
      gmail.googleapis.com \
      drive.googleapis.com \
      sheets.googleapis.com \
      docs.googleapis.com \
      --project="$GCLOUD_PROJECT" 2>/dev/null || true
  fi
fi

# Verify Google Workspace OAuth Client ID key file
GMAIL_KEYS="$HOME/.gmail-mcp/gcp-oauth.keys.json"
DRIVE_KEYS="$HOME/.config/google-drive-mcp/gcp-oauth.keys.json"
GMAIL_TOKENS="$HOME/.gmail-mcp/credentials.json"
DRIVE_TOKENS="$HOME/.config/google-drive-mcp/tokens.json"
export GOOGLE_DRIVE_MCP_SCOPES="$GOOGLE_DRIVE_MCP_SCOPES_REQUIRED"

mkdir -p "$HOME/.gmail-mcp" "$HOME/.config/google-drive-mcp"

# Auto-detect newly downloaded Desktop client secret JSON in ~/Downloads
if [[ ! -f "$GMAIL_KEYS" && ! -f "$DRIVE_KEYS" ]]; then
  LATEST_DOWNLOADED_KEY="$(newest_desktop_oauth_key "$HOME/Downloads")"
  if [[ -n "$LATEST_DOWNLOADED_KEY" ]]; then
    printf 'Found downloaded OAuth Client key: %s\n' "$LATEST_DOWNLOADED_KEY"
    cp "$LATEST_DOWNLOADED_KEY" "$GMAIL_KEYS"
  fi
fi

if [[ -f "$GMAIL_KEYS" && ! -f "$DRIVE_KEYS" ]]; then
  cp "$GMAIL_KEYS" "$DRIVE_KEYS"
elif [[ -f "$DRIVE_KEYS" && ! -f "$GMAIL_KEYS" ]]; then
  cp "$DRIVE_KEYS" "$GMAIL_KEYS"
fi

if [[ ! -f "$GMAIL_KEYS" ]]; then
  CONSOLE_URL="https://console.cloud.google.com/apis/credentials${GCLOUD_PROJECT:+?project=$GCLOUD_PROJECT}"
  open "$CONSOLE_URL" 2>/dev/null || true

  printf '\n========================================================================\n' >&2
  printf '  PREREQUISITE: Google Workspace OAuth Setup\n' >&2
  printf '========================================================================\n' >&2
  printf 'Opened Google Cloud Console in your browser:\n' >&2
  printf '  %s\n\n' "$CONSOLE_URL" >&2
  printf '1. If prompted "Configure consent screen" (First time only):\n' >&2
  printf '   - Click "Configure consent screen" (Google Auth Platform).\n' >&2
  printf '   - Under Branding: Enter App Name ("Bureaucrat") and your email address.\n' >&2
  printf '   - Under Audience: Click "+ Add users" under Test Users, add every account that will authorize Bureaucrat, and save.\n' >&2
  printf '   - Under Data Access: Add only gmail.modify, drive, documents, and spreadsheets.\n\n' >&2
  printf '2. Create & Download Desktop OAuth Key:\n' >&2
  printf '   - In Credentials, click: "+ CREATE CREDENTIALS" -> "OAuth client ID".\n' >&2
  printf '   - Application type: Select "Desktop app" -> Click "Create".\n' >&2
  printf '   - Click "DOWNLOAD JSON" from the popup modal.\n\n' >&2
  printf '3. Launch & Authorize:\n' >&2
  printf '   - Re-run ./launch-bureaucrat.command (auto-detects from ~/Downloads).\n' >&2
  printf '   - Complete the separate Gmail and Google Drive consent flows.\n' >&2
  printf '   - External Testing authorizations expire after seven days; use --reauthorize to renew them.\n' >&2
  printf '========================================================================\n\n' >&2
  exit 4
fi

authorize_gmail() {
  printf '\n[Gmail]: Opening the Google authorization flow for scopes [%s]...\n' \
    "$GMAIL_MCP_SCOPES_REQUIRED"
  npx -y @artymclabin/gmail-mcp auth --scopes="$GMAIL_MCP_SCOPES_REQUIRED"
}

authorize_drive() {
  local account_alias="${1:-}"

  printf '\n[Google Drive]: Opening the Google authorization flow for scopes [%s]...\n' \
    "$GOOGLE_DRIVE_MCP_SCOPES_REQUIRED"
  if [[ -n "$account_alias" ]]; then
    printf '[Google Drive]: Reauthorizing account alias [%s]...\n' "$account_alias"
    npx -y @piotr-agier/google-drive-mcp auth "$account_alias"
  else
    npx -y @piotr-agier/google-drive-mcp auth
  fi
}

authorize_drive_accounts() {
  local account_aliases=()
  local account_alias

  if [[ -f "$DRIVE_TOKENS" ]]; then
    while IFS= read -r account_alias; do
      if [[ -n "$account_alias" ]]; then
        account_aliases+=("$account_alias")
      fi
    done < <(google_drive_mcp_account_aliases "$DRIVE_TOKENS")
  fi

  if [[ "${#account_aliases[@]}" -eq 0 ]]; then
    authorize_drive
    return
  fi

  for account_alias in "${account_aliases[@]}"; do
    authorize_drive "$account_alias" || return
  done
}

if [[ -n "$REAUTHORIZE_TARGET" ]]; then
  if [[ "$REAUTHORIZE_TARGET" == "gmail" || "$REAUTHORIZE_TARGET" == "all" ]]; then
    if ! authorize_gmail; then
      printf '\nGmail reauthorization did not complete. Run this command again to retry.\n' >&2
      exit 4
    fi
  fi
  if [[ "$REAUTHORIZE_TARGET" == "drive" || "$REAUTHORIZE_TARGET" == "all" ]]; then
    if ! authorize_drive_accounts; then
      printf '\nGoogle Drive reauthorization did not complete. Run this command again to retry.\n' >&2
      exit 4
    fi
  fi
  printf '\nGoogle Workspace reauthorization completed for [%s].\n' "$REAUTHORIZE_TARGET"
  exit 0
fi

if ! gmail_mcp_authorization_is_current "$GMAIL_TOKENS"; then
  if [[ -f "$GMAIL_TOKENS" ]]; then
    printf '\n[Gmail]: The saved authorization does not match the required scope contract.\n'
  fi
  if ! authorize_gmail; then
    printf '\nGmail authorization did not complete. Please re-run to authorize.\n' >&2
    exit 4
  fi
fi

if ! google_drive_mcp_authorizations_are_current "$DRIVE_TOKENS"; then
  if [[ -f "$DRIVE_TOKENS" ]]; then
    printf '\n[Google Drive]: One or more saved authorizations do not match the required scope contract.\n'
  fi
  if ! authorize_drive_accounts; then
    printf '\nGoogle Drive authorization did not complete. Please re-run to authorize.\n' >&2
    exit 4
  fi
fi

# Session locking
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
STARTED_SERVER=0
cleanup() {
  release_session_lock
  local active_sessions
  active_sessions="$(active_opencode_session_pids || true)"
  if [[ -z "$active_sessions" ]]; then
    printf '\nSession finished. Unloading model to free system memory...\n' >&2
    "$LMS_BIN" unload "$MODEL_ID" >/dev/null 2>&1 || true
    if [[ "$STARTED_SERVER" -eq 1 ]]; then
      printf 'Stopping LM Studio server...\n' >&2
      "$LMS_BIN" server stop >/dev/null 2>&1 || true
    fi
  fi
}
trap cleanup EXIT INT TERM

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
  STARTED_SERVER=1
fi

SERVER_READY=0
for _attempt in {1..30}; do
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
for _attempt in {1..30}; do
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

configure_opencode_environment "bureaucrat"

printf 'Launching [Qwen The Bureaucrat] in %s with %s (%s GiB detected).\n' \
  "$WORKSPACE_DIR" "$MODEL_QUANTIZATION" "$DETECTED_MEMORY_GIB"
cd "$WORKSPACE_DIR"
"$OPENCODE_BIN" "$WORKSPACE_DIR" \
  --model "lmstudio/qwen3.8-27b" \
  --agent "qwen-bureaucrat" \
  "$@"
