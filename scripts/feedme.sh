#!/bin/bash
# feedme: plays a sound when Claude has been waiting for you for a while.
#
# Hook entry points (hooks/hooks.json):
#   feedme.sh arm      Stop: schedule the alert for this session
#   feedme.sh cancel   UserPromptSubmit / PreToolUse / SessionEnd: drop it
#
# User commands (the /feedme:* skills call these):
#   on | off | status | timeout [seconds]

FEEDME_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/config.sh
. "$FEEDME_ROOT/scripts/lib/config.sh"

usage() {
  cat >&2 <<'EOF'
usage: feedme.sh <command>
  on | off                 enable or disable the alert
  status                   show the current settings
  timeout [seconds]        show or set the delay before the alert (1-86400)
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

cmd_status() {
  if cfg_enabled; then echo "feedme: enabled"; else echo "feedme: disabled"; fi
  echo "timeout: $(cfg_timeout)s"
  echo "set: $(cfg_get set "$FEEDME_DEFAULT_SET")"
  echo "config: $(cfg_dir)"
}

command="${1:-}"
[ $# -gt 0 ] && shift
case "$command" in
  on) cmd_on ;;
  off) cmd_off ;;
  status) cmd_status ;;
  timeout) cmd_timeout "$@" ;;
  *) usage ;;
esac
