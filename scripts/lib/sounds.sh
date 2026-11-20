# shellcheck shell=bash
# Sound sets and audio playback.
#
# A sound set is a directory of audio files. Bundled sets live in the plugin's
# sounds/ dir; user sets live in "$(cfg_dir)/sounds" and win on a name clash.
# Only files the current player can decode count, so a set never goes silent
# at random because of one unsupported file.

FEEDME_PLAYER_CANDIDATES="afplay paplay pw-play aplay ffplay mpv"
FEEDME_ALL_EXTS="wav aif aiff mp3 m4a caf flac ogg"

bundled_sounds_dir() { printf '%s\n' "${FEEDME_SOUNDS_DIR:-$FEEDME_ROOT/sounds}"; }
user_sounds_dir() { printf '%s/sounds\n' "$(cfg_dir)"; }

# player_cmd: FEEDME_PLAYER (a single executable), else the first known player.
player_cmd() {
  if [ -n "${FEEDME_PLAYER:-}" ]; then
    command -v "$FEEDME_PLAYER" 2>/dev/null
    return
  fi
  local candidate
  for candidate in $FEEDME_PLAYER_CANDIDATES; do
    command -v "$candidate" 2>/dev/null && return 0
  done
  return 1
}

# player_exts <player>: the file extensions that player decodes.
player_exts() {
  if [ -n "${FEEDME_PLAYER:-}" ]; then
    echo "$FEEDME_ALL_EXTS"
    return
  fi
  case "${1##*/}" in
    afplay) echo "wav aif aiff mp3 m4a caf" ;;
    paplay | pw-play) echo "wav aif aiff flac ogg" ;;
    aplay) echo "wav" ;;
    *) echo "$FEEDME_ALL_EXTS" ;;
  esac
}

# player_missing_reason: why player_cmd found nothing, for the user.
player_missing_reason() {
  if [ -n "${FEEDME_PLAYER:-}" ]; then
    echo "FEEDME_PLAYER=$FEEDME_PLAYER not found"
  else
    echo "no audio player found (looked for: $FEEDME_PLAYER_CANDIDATES)"
  fi
}

# ci_globs "wav mp3": case-insensitive glob words, "[wW][aA][vV] [mM][pP]3".
ci_globs() {
  local lower="$1" upper out="" i c u
  upper="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
  for ((i = 0; i < ${#lower}; i++)); do
    c="${lower:i:1}"
    u="${upper:i:1}"
    if [ "$c" = "$u" ]; then out="$out$c"; else out="${out}[$c$u]"; fi
  done
  printf '%s\n' "$out"
}

# sound_files <dir>: playable files in a set, one per line. One glob per
# extension rather than a test per file, so big sets stay fast.
sound_files() {
  local globs glob file
  read -r -a globs <<< "$(ci_globs "$(player_exts "$(player_cmd)")")"
  for glob in "${globs[@]}"; do
    # $glob is unquoted on purpose: it is a pattern.
    # shellcheck disable=SC2231
    for file in "$1"/*.$glob; do
      [ -f "$file" ] && printf '%s\n' "$file"
    done
  done
}

count_sounds() { sound_files "$1" | grep -c .; }

# set_path <name>: the directory of a usable set (user first), or exit 1.
set_path() {
  valid_name "$1" || return 1
  local base
  for base in "$(user_sounds_dir)" "$(bundled_sounds_dir)"; do
    if [ -d "$base/$1" ] && [ "$(count_sounds "$base/$1")" -gt 0 ]; then
      printf '%s\n' "$base/$1"
      return 0
    fi
  done
  return 1
}

# set_names: every usable set name, sorted, without duplicates.
set_names() {
  local base dir name
  for base in "$(user_sounds_dir)" "$(bundled_sounds_dir)"; do
    for dir in "$base"/*/; do
      [ -d "$dir" ] || continue
      name="${dir%/}"
      name="${name##*/}"
      set_path "$name" >/dev/null && printf '%s\n' "$name"
    done
  done | sort -u
}

# active_set: the configured set, else "feedme", else the first set available.
active_set() {
  local configured
  configured="$(cfg_get set "$FEEDME_DEFAULT_SET")"
  if set_path "$configured" >/dev/null; then
    printf '%s\n' "$configured"
  elif set_path "$FEEDME_DEFAULT_SET" >/dev/null; then
    printf '%s\n' "$FEEDME_DEFAULT_SET"
  else
    set_names | head -n 1
  fi
}

# pick_sound <set>: a random playable file from the set.
pick_sound() {
  local dir files=() file
  dir="$(set_path "$1")" || return 1
  while IFS= read -r file; do
    files[${#files[@]}]="$file"
  done < <(sound_files "$dir")
  [ "${#files[@]}" -gt 0 ] || return 1
  printf '%s\n' "${files[RANDOM % ${#files[@]}]}"
}

# play_file <path>: plays and waits; silently does nothing without a player.
play_file() {
  local player
  player="$(player_cmd)" || return 0
  case "${player##*/}" in
    ffplay) "$player" -nodisp -autoexit -loglevel quiet "$1" ;;
    mpv) "$player" --no-video --really-quiet "$1" ;;
    *) "$player" "$1" ;;
  esac >/dev/null 2>&1 </dev/null
}

plural_sounds() {
  if [ "$1" = 1 ]; then echo "1 sound"; else echo "$1 sounds"; fi
}
