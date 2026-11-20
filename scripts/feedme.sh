#!/bin/bash
# shellcheck source-path=SCRIPTDIR
# feedme: plays a sound when Claude has been waiting for you for a while.
#
# Hook entry points (hooks/hooks.json):
#   feedme.sh arm      Stop: schedule the alert for this session
#   feedme.sh cancel   UserPromptSubmit / PreToolUse / SessionEnd: drop it
#
# User commands (the /feedme:* skills call these):
#   on | off | status | timeout [seconds] | list | set <name> | play [name]
#   hook add <name> <url> [header...] | hook rm <name> | hook list | hook test [name]

FEEDME_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# shellcheck source=lib/config.sh
. "$FEEDME_ROOT/scripts/lib/config.sh"
# shellcheck source=lib/sounds.sh
. "$FEEDME_ROOT/scripts/lib/sounds.sh"
# shellcheck source=lib/alert.sh
. "$FEEDME_ROOT/scripts/lib/alert.sh"
# shellcheck source=lib/actions.sh
. "$FEEDME_ROOT/scripts/lib/actions.sh"

usage() {
  cat >&2 <<'EOF'
usage: feedme.sh <command>
  on | off                 enable or disable the alert
  status                   show the current settings
  timeout [seconds]        show or set the delay before the alert (1-86400)
  list                     list the sound sets
  set <name>               choose the sound set
  play [name]              play a sound from the active (or named) set now
  hook add <name> <url> ['Header: value'...]
                           call a webhook when the alert fires
  hook rm <name>           remove a webhook
  hook list                list webhooks and scripts (secrets masked)
  hook test [name]         run the actions now
EOF
  exit 2
}

cmd_on() {
  cfg_set enabled 1 || exit 1
  echo "feedme enabled: the alert plays after $(cfg_timeout)s of waiting."
}

cmd_off() {
  cfg_set enabled 0 || exit 1
  echo "feedme disabled."
}

cmd_timeout() {
  if [ $# -eq 0 ]; then
    echo "timeout: $(cfg_timeout)s"
    return
  fi
  if ! is_timeout "$1"; then
    echo "invalid timeout '$1': use a whole number of seconds between 1 and $FEEDME_MAX_TIMEOUT." >&2
    exit 1
  fi
  cfg_set timeout "$1" || exit 1
  echo "timeout set to $1s."
  if [ -n "${FEEDME_DELAY:-}" ]; then
    echo "note: FEEDME_DELAY=$FEEDME_DELAY is set in the environment and overrides it."
  fi
}

cmd_list() {
  local active name dir source names
  names="$(set_names)"
  if [ -z "$names" ]; then
    echo "no sound sets found. Add one as a folder of audio files in $(user_sounds_dir)/"
    return
  fi
  active="$(active_set)"
  # Set names are validated single words, so plain word splitting is safe.
  for name in $names; do
    dir="$(set_path "$name")"
    source=bundled
    case "$dir" in "$(user_sounds_dir)"/*) source=user ;; esac
    if [ "$name" = "$active" ]; then printf '* '; else printf '  '; fi
    echo "$name ($(plural_sounds "$(count_sounds "$dir")"), $source)"
  done
  echo
  echo "Your own sets go in $(user_sounds_dir)/<name>/"
}

cmd_set() {
  local name="${1:-}"
  if ! set_path "$name" >/dev/null; then
    echo "unknown sound set '$name'. Available: $(set_names | tr '\n' ' ')" >&2
    exit 1
  fi
  cfg_set set "$name" || exit 1
  echo "sound set: $name ($(plural_sounds "$(count_sounds "$(set_path "$name")")"))"
}

cmd_play() {
  local name="${1:-$(active_set)}" sound
  if ! player_cmd >/dev/null; then
    echo "$(player_missing_reason)."
    return 0
  fi
  if ! sound="$(pick_sound "$name")"; then
    echo "unknown or empty sound set '$name'." >&2
    exit 1
  fi
  play_file "$sound"
  echo "played ${sound##*/} from $name"
}

cmd_status() {
  local set player
  if cfg_enabled; then echo "feedme: enabled"; else echo "feedme: disabled"; fi
  echo "timeout: $(cfg_timeout)s"
  set="$(active_set)"
  if [ -n "$set" ]; then
    echo "set: $set ($(plural_sounds "$(count_sounds "$(set_path "$set")")"))"
  else
    echo "set: none (no sound sets found)"
  fi
  if player="$(player_cmd)"; then
    echo "player: $player"
  else
    echo "player: none, $(player_missing_reason)"
  fi
  local actions
  actions="$(action_names)"
  if [ -n "$actions" ]; then
    echo "actions: $(echo "$actions" | tr ',' '\n' | grep -c .) ($actions)"
  else
    echo "actions: none"
  fi
  echo "config: $(cfg_dir)"
}

cmd_hook() {
  local sub="${1:-list}"
  [ $# -gt 0 ] && shift
  case "$sub" in
    add) hook_add "$@" ;;
    rm | remove) hook_rm "$@" ;;
    list) hook_list ;;
    test) hook_test "$@" ;;
    *) usage ;;
  esac
}

command="${1:-}"
[ $# -gt 0 ] && shift
case "$command" in
  # Hook paths: never print, never fail (see lib/alert.sh).
  arm) cmd_arm >/dev/null 2>&1; exit 0 ;;
  cancel) cmd_cancel >/dev/null 2>&1; exit 0 ;;
  fire) cmd_fire "$@" >/dev/null 2>&1; exit 0 ;;
  on) cmd_on ;;
  off) cmd_off ;;
  status) cmd_status ;;
  timeout) cmd_timeout "$@" ;;
  list) cmd_list ;;
  set) cmd_set "$@" ;;
  play) cmd_play "$@" ;;
  hook) cmd_hook "$@" || exit 1 ;;
  *) usage ;;
esac
