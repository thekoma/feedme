# shellcheck shell=bash
# Actions run when the alert fires, next to the sound. They live in
# "$(cfg_dir)/hooks.d":
#
#   <name>.webhook   url= line plus any number of header= lines; feedme POSTs a
#                    small JSON body to the URL. Written by `hook add`.
#   <name>           any executable file, run with FEEDME_* variables set.
#
# Webhook URLs and headers often carry secrets, so files are created 0600 in a
# 0700 dir, listings mask them, and curl reads them from stdin instead of argv
# (argv is visible to every local user through ps).

FEEDME_DEFAULT_ACTION_TIMEOUT=10

hooks_dir() { printf '%s/hooks.d\n' "$(cfg_dir)"; }

action_timeout() {
  if is_timeout "${FEEDME_ACTION_TIMEOUT:-}"; then echo "$FEEDME_ACTION_TIMEOUT"; else echo "$FEEDME_DEFAULT_ACTION_TIMEOUT"; fi
}

valid_url() {
  case "$1" in
    *[[:space:][:cntrl:]]*) return 1 ;;
    http://?* | https://?*) return 0 ;;
    *) return 1 ;;
  esac
}

# valid_header "Name: value"
valid_header() {
  local name="${1%%:*}" value="${1#*:}"
  case "$1" in *:*) ;; *) return 1 ;; esac
  case "$1" in *[[:cntrl:]]*) return 1 ;; esac
  case "$name" in '' | *[!A-Za-z0-9-]*) return 1 ;; esac
  case "$value" in *[![:space:]]*) return 0 ;; *) return 1 ;; esac
}

# mask_url: keep scheme and host:port, hide credentials, path and query.
mask_url() {
  local scheme="${1%%://*}" rest="${1#*://}" authority
  authority="${rest%%[/?#]*}"
  authority="${authority##*@}"
  if [ "$rest" = "$authority" ]; then
    echo "$scheme://$authority"
  else
    echo "$scheme://$authority/***"
  fi
}

mask_header() { echo "${1%%:*}: ***"; }

# json_string <text>: a JSON string literal, control characters escaped.
json_string() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '"%s"' "$(printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037')"
}

# curl_quote <text>: a double-quoted value for a curl config file.
curl_quote() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '"%s"' "$s"
}

# webhook_field <file> url|header: the values of one key, one per line.
webhook_field() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "$2="*) printf '%s\n' "${line#*=}" ;; esac
  done < "$1"
}

# action_files [name]: webhook files and executable scripts, sorted by name.
action_files() {
  local file name
  for file in "$(hooks_dir)"/*; do
    [ -f "$file" ] || continue
    name="${file##*/}"
    case "$name" in
      *.webhook) name="${name%.webhook}" ;;
      *) [ -x "$file" ] || continue ;;
    esac
    [ -z "${1:-}" ] || [ "$1" = "$name" ] || continue
    printf '%s\n' "$file"
  done
}

action_name() {
  local name="${1##*/}"
  echo "${name%.webhook}"
}

# call_webhook <file>: POST the alert as JSON; prints the HTTP status.
call_webhook() {
  local url header body
  url="$(webhook_field "$1" url | head -n 1)"
  valid_url "$url" || { echo "invalid url"; return 1; }
  body="{\"event\":\"feedme\",\"set\":$(json_string "${FEEDME_SET:-}"),\"session_id\":$(json_string "${FEEDME_SESSION_ID:-}"),\"cwd\":$(json_string "${FEEDME_CWD:-}")}"
  {
    echo "url = $(curl_quote "$url")"
    echo "header = $(curl_quote "Content-Type: application/json")"
    webhook_field "$1" header | while IFS= read -r header; do
      echo "header = $(curl_quote "$header")"
    done
  } | curl -s -o /dev/null -m 5 -X POST -w '%{http_code}' --data "$body" --config -
}

# run_with_timeout <seconds> <cmd...>: kill the command (and its children) when
# it overruns, so one stuck script cannot keep `fire` alive forever.
run_with_timeout() {
  local seconds="$1" pid watchdog status
  shift
  "$@" </dev/null &
  pid=$!
  (
    sleep "$seconds"
    pkill -P "$pid" 2>/dev/null
    kill "$pid" 2>/dev/null
  ) &
  watchdog=$!
  wait "$pid" 2>/dev/null
  status=$?
  pkill -P "$watchdog" 2>/dev/null
  kill "$watchdog" 2>/dev/null
  return "$status"
}

# run_action <file>: run one action in the foreground; prints a one-line result.
run_action() {
  local name status code
  name="$(action_name "$1")"
  case "$1" in
    *.webhook)
      code="$(call_webhook "$1")"
      status=$?
      if [ "$status" -eq 0 ]; then
        echo "$name: HTTP $code"
      else
        echo "$name: request failed (curl exit $status${code:+, $code})"
      fi
      ;;
    *)
      run_with_timeout "$(action_timeout)" "$1" >/dev/null 2>&1
      echo "$name: exit $?"
      ;;
  esac
}

# run_actions <set> <sound> <session> <cwd>: every action, in parallel.
run_actions() {
  local file
  export FEEDME_SET="$1" FEEDME_SOUND="$2" FEEDME_SESSION_ID="$3" FEEDME_CWD="$4"
  while IFS= read -r file; do
    run_action "$file" >/dev/null 2>&1 &
  done < <(action_files)
  wait
}

hook_add() {
  local name="${1:-}" url="${2:-}" header file tmp
  if ! valid_name "$name"; then
    echo "invalid name '$name': use letters, digits, '.', '_' or '-'." >&2
    return 1
  fi
  if ! valid_url "$url"; then
    echo "invalid url: it must start with http:// or https:// and contain no spaces." >&2
    echo "Tip: single-quote it, or the shell cuts it at '&', ';' or '#'." >&2
    return 1
  fi
  shift 2
  for header in "$@"; do
    if ! valid_header "$header"; then
      echo "invalid header '$(mask_header "$header")': use 'Name: value'." >&2
      return 1
    fi
  done
  (umask 077 && mkdir -p "$(hooks_dir)") || return 1
  chmod 700 "$(hooks_dir)"
  file="$(hooks_dir)/$name.webhook"
  tmp="$(umask 077 && mktemp "$(hooks_dir)/.webhook.XXXXXX")" || return 1
  if ! {
    echo "url=$url"
    for header in "$@"; do echo "header=$header"; done
  } > "$tmp" || ! mv -f "$tmp" "$file"; then
    rm -f "$tmp"
    return 1
  fi
  echo "saved webhook '$name': $(mask_url "$url") (URL is ${#url} characters)"
  for header in "$@"; do echo "  header $(mask_header "$header")"; done
}

hook_rm() {
  local name="${1:-}" file
  valid_name "$name" || { echo "invalid name '$name'." >&2; return 1; }
  file="$(hooks_dir)/$name.webhook"
  if [ -f "$file" ]; then
    rm -f "$file" && echo "removed webhook '$name'."
  elif [ -f "$(hooks_dir)/$name" ]; then
    echo "'$name' is a script, not a webhook: delete $(hooks_dir)/$name yourself." >&2
    return 1
  else
    echo "no webhook named '$name'." >&2
    return 1
  fi
}

hook_list() {
  local file name found=""
  while IFS= read -r file; do
    found=1
    name="$(action_name "$file")"
    case "$file" in
      *.webhook)
        echo "$name  webhook  $(mask_url "$(webhook_field "$file" url | head -n 1)")"
        webhook_field "$file" header | while IFS= read -r header; do
          echo "    header $(mask_header "$header")"
        done
        ;;
      *) echo "$name  script   $file" ;;
    esac
  done < <(action_files)
  if [ -z "$found" ]; then
    echo "no actions yet."
    echo "Add a webhook: /feedme:hook add <name> '<url>' ['Header: value'...]"
    echo "Or drop an executable script in $(hooks_dir)/"
  fi
}

# hook_test [name]: run the actions now, in the foreground, and report.
hook_test() {
  local file ran=""
  export FEEDME_SET FEEDME_SOUND="" FEEDME_SESSION_ID=test FEEDME_CWD="$PWD"
  FEEDME_SET="$(active_set)"
  while IFS= read -r file; do
    ran=1
    run_action "$file"
  done < <(action_files "${1:-}")
  if [ -z "$ran" ]; then
    if [ -n "${1:-}" ]; then echo "no action named '$1'." >&2; else echo "no actions to run."; fi
    [ -z "${1:-}" ]
  fi
}

action_names() {
  local file names=""
  while IFS= read -r file; do
    names="${names:+$names, }$(action_name "$file")"
  done < <(action_files)
  echo "$names"
}
