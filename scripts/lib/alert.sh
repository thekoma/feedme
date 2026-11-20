# shellcheck shell=bash
# The alert lifecycle, driven by Claude Code hooks.
#
#   arm     (Stop) writes a fresh token for the session and starts a detached
#           `fire` that owns that token.
#   cancel  (UserPromptSubmit, PreToolUse, SessionEnd) deletes the token.
#   fire    waits the timeout in one-second steps, quitting as soon as its token
#           is gone or replaced, then plays a sound and runs the user actions.
#
# These run inside hooks: they must stay silent and always exit 0, because a
# non-zero exit (2 above all) would block the prompt, the tool call or Stop.

# Per-user and private: on Linux /tmp is shared between users.
state_dir() {
  printf '%s\n' "${FEEDME_STATE_DIR:-${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/claude-feedme-$(id -u)}"
}

# ensure_state_dir: create it 0700, and refuse one that is a symlink or not ours.
ensure_state_dir() {
  local dir
  dir="$(state_dir)"
  [ -L "$dir" ] && return 1
  [ -d "$dir" ] || mkdir -m 700 "$dir" 2>/dev/null || return 1
  [ ! -L "$dir" ] && [ -d "$dir" ] && [ -O "$dir" ] || return 1
  printf '%s\n' "$dir"
}

# Hook input arrives as JSON on stdin; an interactive run has none.
read_hook_input() {
  [ -t 0 ] || cat
}

# json_field <json> <key>: a top-level string field, with jq when available.
# Without jq, the first `"key": "value"` in the text wins, so a nested copy of
# the key (say, inside tool_input) cannot shadow the real one.
json_field() {
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$1" | jq -r --arg k "$2" 'if type == "object" then (.[$k] // empty | tostring) else empty end' 2>/dev/null
  else
    printf '%s' "$1" | tr '\n' ' ' \
      | grep -o "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -n 1 \
      | sed 's/^[^:]*:[[:space:]]*"//; s/"$//'
  fi
}

# session_key <json>: the session id reduced to a safe file name, or "default".
session_key() {
  local id
  id="$(json_field "$1" session_id | tr -cd 'A-Za-z0-9_-')"
  id="${id:0:128}"
  printf '%s\n' "${id:-default}"
}

trace() {
  [ -n "${FEEDME_TRACE:-}" ] && printf '%s %s\n' "$1" "$2" >> "$FEEDME_TRACE"
  return 0
}

# spawn_session <cmd...>: run the command in the background as the leader of a
# new session, with no inherited stdio. It then outlives the hook's process
# group, and its whole process group can be signalled through -$!.
spawn_session() {
  (
    if command -v perl >/dev/null 2>&1; then
      # Block form of exec: never hand a single argument to /bin/sh.
      exec perl -MPOSIX -e 'POSIX::setsid(); exec { $ARGV[0] } @ARGV or die' "$@"
    elif command -v setsid >/dev/null 2>&1; then
      exec setsid "$@"
    else
      exec nohup "$@"
    fi
  ) </dev/null >/dev/null 2>&1 &
}

cmd_arm() {
  local input session dir token tmp
  input="$(read_hook_input)"
  session="$(session_key "$input")"
  trace arm "$session"
  cfg_enabled || return 0
  dir="$(ensure_state_dir)" || return 0
  token="$$.$RANDOM.$(date +%s)"
  tmp="$(mktemp "$dir/.token.XXXXXX")" || return 0
  if ! { printf '%s\n' "$token" > "$tmp" && mv -f "$tmp" "$dir/$session"; }; then
    rm -f "$tmp"
    return 0
  fi
  spawn_session "$FEEDME_ROOT/scripts/feedme.sh" fire "$dir/$session" "$token" "$session" \
    "$(json_field "$input" cwd)"
}

cmd_cancel() {
  local session dir
  session="$(session_key "$(read_hook_input)")"
  trace cancel "$session"
  dir="$(state_dir)"
  [ -L "$dir" ] || rm -f "$dir/$session"
}

# still_owner <pending> <token>: the alert is still ours to fire.
still_owner() {
  local current=""
  read -r current < "$1" 2>/dev/null
  [ "$current" = "$2" ]
}

cmd_fire() {
  local pending="$1" token="$2" session="$3" cwd="$4" timeout waited=0 set sound=""
  timeout="$(cfg_timeout)"
  while [ "$waited" -lt "$timeout" ]; do
    sleep 1
    waited=$((waited + 1))
    still_owner "$pending" "$token" || return 0
  done
  rm -f "$pending"
  cfg_enabled || return 0
  trace fire "$session"
  set="$(active_set)"
  [ -n "$set" ] && sound="$(pick_sound "$set")"
  run_actions "$set" "$sound" "$session" "$cwd" &
  [ -n "$sound" ] && play_file "$sound"
  wait
}
