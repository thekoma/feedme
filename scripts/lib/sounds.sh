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

# A set name is a single path component: no slashes, no leading dot.
valid_set_name() {
  case "$1" in '' | .* | *[!A-Za-z0-9._-]*) return 1 ;; esac
}

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

# sound_files <dir>: playable files in a set, one per line.
sound_files() {
  local exts file ext
  exts=" $(player_exts "$(player_cmd)") "
  for file in "$1"/*; do
    [ -f "$file" ] || continue
    case "$file" in *.*) ;; *) continue ;; esac
    ext="$(printf '%s' "${file##*.}" | tr '[:upper:]' '[:lower:]')"
    case "$exts" in *" $ext "*) printf '%s\n' "$file" ;; esac
  done
}

count_sounds() { sound_files "$1" | grep -c .; }

# set_path <name>: the directory of a usable set (user first), or exit 1.
set_path() {
  valid_set_name "$1" || return 1
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
