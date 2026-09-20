#!/bin/bash

SPLASH_FORMULA="incoai/tap/splash"
SPLASH_URL="http://127.0.0.1:8000"
SPLASH_MODEL_ID="incoai/Qwen3.8-27B-Splash"
SPLASH_MAX_CONTEXT=262144
SPLASH_STARTUP_SECONDS=1800
SPLASH_SERVER_PID=""
SPLASH_LOG_FILE=""

ensure_splash_installed() {
  if command -v splash >/dev/null 2>&1; then
    return 0
  fi
  local brew_bin
  brew_bin="$(command -v brew || true)"
  if [[ -z "$brew_bin" ]]; then
    printf 'Splash is missing. Install Homebrew from https://brew.sh, then run this command again.\n' >&2
    return 3
  fi
  printf 'Installing Splash through Homebrew...\n'
  if ! "$brew_bin" install "$SPLASH_FORMULA"; then
    printf 'Could not install Splash with Homebrew (%s). See the installation error above.\n' "$SPLASH_FORMULA" >&2
    return 3
  fi
  hash -r
  if ! command -v splash >/dev/null 2>&1; then
    printf 'Homebrew completed, but splash is not in PATH. Load the Homebrew shell environment, then run this command again.\n' >&2
    return 3
  fi
}

prepare_splash_runtime() {
  if ! splash_is_listening; then
    ensure_splash_installed
  fi
}

initialize_splash_profile() {
  if [[ -n "${SPLASH_PORT+x}" ]]; then
    printf 'Splash uses port 8000. Unset SPLASH_PORT before launch.\n' >&2
    return 2
  fi
  for dependency in curl jq; do
    if ! command -v "$dependency" >/dev/null 2>&1; then
      printf 'Splash integration requires %s. Run bash "%s/install.command" --backend splash.\n' "$dependency" "$PROFILE_ROOT" >&2
      return 3
    fi
  done
  MODEL_ID="$SPLASH_MODEL_ID"
  MODEL_DISPLAY_NAME="Qwen 3.8 27B Splash 4-bit + DFlash 2"
  MODEL_QUANTIZATION="4-bit"
  OPENCODE_MODEL="splash/$MODEL_ID"
  PROFILE_TIER="splash"
  # Offline diagnostics use a bounded profile; launch always reads the live limit.
  CONTEXT_LENGTH=32768
  OUTPUT_LIMIT=8192
  COMPACTION_RESERVED="$OUTPUT_LIMIT"
}

splash_api() {
  local route="$1"
  shift
  local headers=(-H "Accept: application/json")
  if [[ -n "${SPLASH_API_KEY:-}" ]]; then
    headers=(-H "Authorization: Bearer $SPLASH_API_KEY")
  fi
  curl -fsS --connect-timeout 2 --max-time 10 "${headers[@]}" "$SPLASH_URL$route" "$@"
}

splash_is_listening() {
  curl -sS --connect-timeout 1 --max-time 2 -o /dev/null "$SPLASH_URL/ready" 2>/dev/null
}

read_splash_runtime() {
  local models status context
  if ! splash_api /ready | jq -e '.status == "ready"' >/dev/null; then
    printf 'The service at %s is not a ready Splash server. Check the process using this address.\n' "$SPLASH_URL" >&2
    return 5
  fi
  if ! models="$(splash_api /v1/models)" || ! jq -e --arg model "$MODEL_ID" \
    '.data | length == 1 and .[0].id == $model' <<<"$models" >/dev/null; then
    printf 'Splash at %s must serve %s. Check the model and SPLASH_API_KEY.\n' "$SPLASH_URL" "$MODEL_ID" >&2
    return 5
  fi
  if ! status="$(splash_api /status)" || ! context="$(jq -er \
    --arg model "$MODEL_ID" --argjson maximum "$SPLASH_MAX_CONTEXT" '
      select(.ready == true and .instance.model == $model) |
      .maximum_context_tokens |
      select(type == "number") |
      select(. == floor and . >= 4096 and . <= $maximum)
    ' <<<"$status")"; then
    printf 'Splash at %s did not report a valid ready context limit for %s.\n' "$SPLASH_URL" "$MODEL_ID" >&2
    return 5
  fi
  CONTEXT_LENGTH="$context"
  OUTPUT_LIMIT=$((CONTEXT_LENGTH / 4))
  (( OUTPUT_LIMIT <= 32768 )) || OUTPUT_LIMIT=32768
  COMPACTION_RESERVED="$OUTPUT_LIMIT"
}

splash_config_content() {
  jq -c --arg model "$MODEL_ID" --arg selection "$OPENCODE_MODEL" \
    --arg name "$MODEL_DISPLAY_NAME" --arg endpoint "$SPLASH_URL/v1" \
    --argjson context "$CONTEXT_LENGTH" --argjson output "$OUTPUT_LIMIT" '
    .enabled_providers = ["splash"] |
    .disabled_providers = ((.disabled_providers // []) | map(select(. != "splash"))) |
    .model = $selection | .small_model = $selection |
    .agent |= with_entries(.value.model = $selection) |
    .provider = {splash: {
      npm: "@ai-sdk/openai-compatible", name: "Splash",
      options: {baseURL: $endpoint, apiKey: "{env:SPLASH_API_KEY}", timeout: 1800000},
      models: {($model): {
        id: $model, name: $name, attachment: true, reasoning: true, tool_call: true,
        interleaved: {field: "reasoning_content"},
        modalities: {input: ["text", "image", "pdf"], output: ["text"]},
        limit: {context: $context, input: ($context - $output), output: $output},
        options: {reasoningEffort: "medium"},
        variants: {none: {reasoningEffort: "none"}, low: {reasoningEffort: "low"},
                   medium: {reasoningEffort: "medium"}, xhigh: {reasoningEffort: "xhigh"}}
      }}
    }} |
    .compaction.reserved = $output
  '
}

stop_owned_splash() {
  if [[ -n "$SPLASH_SERVER_PID" ]]; then
    if kill -0 "$SPLASH_SERVER_PID" 2>/dev/null; then
      printf '\nStopping the Splash server started by this session...\n' >&2
      kill -TERM "$SPLASH_SERVER_PID"
    fi
    wait "$SPLASH_SERVER_PID" || : # A terminated server can return a signal status.
    SPLASH_SERVER_PID=""
  fi
  release_session_lock
}

show_splash_startup_log() {
  printf 'Splash log: %s (last 80 lines)\n' "$SPLASH_LOG_FILE" >&2
  tail -n 80 "$SPLASH_LOG_FILE" >&2
}

start_splash_session() {
  if [[ -n "$(active_opencode_session_pids)" ]] || ! acquire_session_lock; then
    printf 'The dedicated local model already has an OpenCode session.\n' >&2
    return 7
  fi
  trap stop_owned_splash EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  if splash_is_listening; then
    read_splash_runtime
    return $?
  fi
  ensure_splash_installed || return $?
  local log_dir="$HOME/Library/Logs/QwenOC"
  if ! mkdir -p "$log_dir" || ! SPLASH_LOG_FILE="$(mktemp "$log_dir/splash.XXXXXX")"; then
    printf 'Could not create a Splash log in %s.\n' "$log_dir" >&2
    return 5
  fi
  printf 'Starting Splash with %s. The first run downloads about 17.4 GB.\n' "$MODEL_ID"
  printf 'Splash log: %s\n' "$SPLASH_LOG_FILE"
  splash serve --model "$MODEL_ID" </dev/null >"$SPLASH_LOG_FILE" 2>&1 &
  SPLASH_SERVER_PID=$!
  local started_at="$SECONDS"
  while (( SECONDS - started_at < SPLASH_STARTUP_SECONDS )); do
    if ! kill -0 "$SPLASH_SERVER_PID" 2>/dev/null; then
      printf 'Splash stopped before readiness.\n' >&2
      show_splash_startup_log
      return 5
    fi
    if splash_api /ready 2>/dev/null | jq -e '.status == "ready"' >/dev/null; then
      if read_splash_runtime; then
        return 0
      fi
      show_splash_startup_log
      return 5
    fi
    sleep 1
  done
  printf 'Splash did not become ready within %s seconds.\n' "$SPLASH_STARTUP_SECONDS" >&2
  show_splash_startup_log
  return 5
}

launch_splash_opencode() {
  local role="$1" project="$2" agent
  shift 2
  for option in "$@"; do
    case "$option" in
      --model|--model=*|-m|-m?*|--agent|--agent=*)
        printf 'Splash mode selects its model and agent. Remove %s.\n' "$option" >&2
        return 2 ;;
    esac
  done
  start_splash_session || return $?
  configure_opencode_environment "$role" || return $?
  if [[ "$role" == "bureaucrat" ]]; then agent=qwen-bureaucrat; else agent=qwen-local; fi
  printf 'Launching %s with %s (%s-token context).\n' "$agent" "$MODEL_DISPLAY_NAME" "$CONTEXT_LENGTH"
  cd "$project" || return
  "$OPENCODE_BIN" "$project" --model "$OPENCODE_MODEL" --agent "$agent" "$@"
}
