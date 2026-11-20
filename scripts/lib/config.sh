# shellcheck shell=bash
# Settings live in "$(cfg_dir)/config" as key=value lines. The file is parsed,
# never sourced, so a broken or hostile line can only fall back to a default.
#
# Keys: enabled (1|0), timeout (seconds), set (sound set name).

# shellcheck disable=SC2034  # used by the scripts that source this file
FEEDME_DEFAULT_TIMEOUT=10
FEEDME_MAX_TIMEOUT=86400
FEEDME_DEFAULT_SET=feedme

# Outside the plugin dir on purpose: survives plugin updates and is shared by
# every Claude Code profile (CLAUDE_CONFIG_DIR) on the machine.
cfg_dir() {
  printf '%s\n' "${FEEDME_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/feedme}"
}

# cfg_get <key> <default>: the last assignment wins; missing or empty → default.
cfg_get() {
  local file value=""
  file="$(cfg_dir)/config"
  [ -f "$file" ] && value="$(grep -E "^$1=" "$file" 2>/dev/null | tail -n 1)"
  value="${value#*=}"
  if [ -n "$value" ]; then printf '%s\n' "$value"; else printf '%s\n' "$2"; fi
}

# cfg_set <key> <value>: atomic rewrite, other keys untouched.
cfg_set() {
  local dir file tmp
  dir="$(cfg_dir)"
  file="$dir/config"
  mkdir -p "$dir" || return 1
  tmp="$(mktemp "$dir/.config.XXXXXX")" || return 1
  {
    [ -f "$file" ] && grep -vE "^$1=" "$file"
    printf '%s=%s\n' "$1" "$2"
  } > "$tmp" && mv -f "$tmp" "$file"
}

# valid_name: a set or action name is one path component: letters, digits,
# '.', '_' and '-', no leading dot.
valid_name() {
  case "$1" in '' | .* | *[!A-Za-z0-9._-]*) return 1 ;; esac
}

cfg_enabled() {
  [ "$(cfg_get enabled 1)" != 0 ]
}

# is_timeout <value>: a whole number of seconds in 1..FEEDME_MAX_TIMEOUT.
# Leading zeros are refused: bash would read "010" as octal.
is_timeout() {
  case "$1" in '' | *[!0-9]* | 0*) return 1 ;; esac
  [ "${#1}" -le 5 ] && [ "$1" -le "$FEEDME_MAX_TIMEOUT" ]
}

# cfg_timeout: FEEDME_DELAY env, else the config value, else the default.
cfg_timeout() {
  local value
  for value in "${FEEDME_DELAY:-}" "$(cfg_get timeout "")"; do
    if is_timeout "$value"; then
      printf '%s\n' "$value"
      return
    fi
  done
  printf '%s\n' "$FEEDME_DEFAULT_TIMEOUT"
}
