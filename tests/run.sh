#!/bin/bash
# Fake tools are written as single-quoted bash bodies on purpose.
# shellcheck disable=SC2016
# feedme test suite. Plain bash, no dependencies beyond the plugin's own.
#
#   /bin/bash tests/run.sh            run every test
#   /bin/bash tests/run.sh test_name  run only the named tests
#
# Run it with /bin/bash on macOS: that is bash 3.2, the oldest shell we support.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FEEDME="$ROOT/scripts/feedme.sh"

# ---------------------------------------------------------------------------
# Harness
# ---------------------------------------------------------------------------

# Fresh, isolated config/state/sounds dirs and a fake audio player for each test.
t_setup() {
  T="$(mktemp -d "${TMPDIR:-/tmp}/feedme-test.XXXXXX")"
  T="$(cd "$T" && pwd -P)"
  export FEEDME_CONFIG_DIR="$T/config"
  export FEEDME_STATE_DIR="$T/state"
  export FEEDME_SOUNDS_DIR="$T/sounds"
  export FEEDME_TRACE="$T/trace"
  unset FEEDME_DELAY XDG_RUNTIME_DIR
  mkdir -p "$T/bin"
  make_set bundled feedme clip.wav
  # The fake player logs "<argc>:<first arg>" so tests can check quoting.
  make_tool fakeplay 'printf "%s:%s\n" "$#" "$1" >> "'"$T"'/played"'
  export FEEDME_PLAYER="$T/bin/fakeplay"
}

t_teardown() {
  # Stop any detached `fire` left behind by a test; they all carry $T in argv.
  local pids
  pids="$(pgrep -f -- "$T")"
  # shellcheck disable=SC2086  # one pid per word
  [ -n "$pids" ] && kill $pids 2>/dev/null
  rm -rf "$T"
}

# make_set bundled|user <set> <file>...  creates (empty) sound files in a set.
make_set() {
  local where="$1" set="$2" dir
  shift 2
  if [ "$where" = user ]; then dir="$FEEDME_CONFIG_DIR/sounds/$set"; else dir="$FEEDME_SOUNDS_DIR/$set"; fi
  mkdir -p "$dir"
  local f
  for f in "$@"; do : > "$dir/$f"; done
}

# make_tool <name> <bash body>  puts an executable in $T/bin.
make_tool() {
  printf '#!/bin/bash\n%s\n' "$2" > "$T/bin/$1"
  chmod +x "$T/bin/$1"
}

fm() { "$FEEDME" "$@"; }

# path_without <cmd>...  prints a PATH holding every system tool except those named,
# so a test can simulate a machine without jq, afplay and so on.
path_without() {
  local dir="$T/sys" f name
  mkdir -p "$dir"
  for f in /usr/bin/* /bin/*; do
    name="${f##*/}"
    case " $* " in *" $name "*) continue ;; esac
    [ -e "$dir/$name" ] || ln -s "$f" "$dir/$name"
  done
  printf '%s\n' "$dir"
}

NO_PLAYERS=(afplay paplay pw-play aplay ffplay mpv)

fail() { echo "    $*"; exit 1; }

assert_eq() { [ "$1" = "$2" ] || fail "expected [$2], got [$1]"; }

assert_contains() {
  case "$1" in *"$2"*) ;; *) fail "expected output to contain [$2], got:
$1" ;; esac
}

assert_not_contains() {
  case "$1" in *"$2"*) fail "expected output NOT to contain [$2], got:
$1" ;; esac
}

# assert_fail <cmd...>  the command must exit non-zero.
assert_fail() { "$@" >/dev/null 2>&1 && fail "expected failure: $*"; return 0; }

# wait_for <seconds> <test-expression...>  polls until the expression holds.
wait_for() {
  local deadline=$(( $(date +%s) + $1 ))
  shift
  while ! "$@"; do
    [ "$(date +%s)" -ge "$deadline" ] && return 1
    sleep 0.1
  done
}

played_count() { if [ -f "$T/played" ]; then wc -l < "$T/played" | tr -d ' '; else echo 0; fi; }
has_played() { [ "$(played_count)" -ge 1 ]; }

# Hook input as Claude Code sends it on stdin.
hook_json() { printf '{"session_id":"%s","cwd":"/work","hook_event_name":"Stop"}' "$1"; }

fire_running() { pgrep -f -- "feedme.sh fire $T" >/dev/null; }

# ---------------------------------------------------------------------------
# Config: on / off / status / timeout
# ---------------------------------------------------------------------------

test_defaults() {
  local out
  out="$(fm status)"
  assert_contains "$out" "feedme: enabled"
  assert_contains "$out" "timeout: 10s"
  assert_contains "$out" "set: feedme"
}

test_off_on() {
  fm off >/dev/null
  assert_contains "$(fm status)" "feedme: disabled"
  fm on >/dev/null
  assert_contains "$(fm status)" "feedme: enabled"
}

test_timeout_set() {
  fm timeout 42 >/dev/null || fail "timeout 42 failed"
  assert_contains "$(fm status)" "timeout: 42s"
  assert_contains "$(fm timeout)" "42"
}

test_timeout_invalid() {
  local v
  for v in abc 0 86401 -5 1.5 ''; do
    assert_fail fm timeout "$v"
  done
  assert_contains "$(fm status)" "timeout: 10s"
}

test_env_delay_override() {
  fm timeout 42 >/dev/null
  assert_contains "$(FEEDME_DELAY=3 fm status)" "timeout: 3s"
}

test_corrupt_config() {
  mkdir -p "$FEEDME_CONFIG_DIR"
  printf 'garbage line\ntimeout=abc\n=x\nenabled=maybe\n$(touch %s/pwned)\n' "$T" > "$FEEDME_CONFIG_DIR/config"
  local out
  out="$(fm status)"
  assert_contains "$out" "timeout: 10s"
  assert_contains "$out" "feedme: enabled"
  [ -e "$T/pwned" ] && fail "config content was executed"
  return 0
}

test_unknown_command() {
  fm frobnicate >/dev/null 2>&1
  assert_eq "$?" 2
}

# ---------------------------------------------------------------------------
# Sound sets: list / set / play
# ---------------------------------------------------------------------------

test_list_bundled_and_user() {
  make_set bundled a x.wav y.wav
  make_set bundled b z.wav
  make_set user c w.wav
  fm set a >/dev/null || fail "set a failed"
  local out
  out="$(fm list)"
  assert_contains "$out" "* a (2 sounds, bundled)"
  assert_contains "$out" "  b (1 sound, bundled)"
  assert_contains "$out" "  c (1 sound, user)"
  assert_contains "$out" "  feedme (1 sound, bundled)"
}

test_user_overrides_bundled() {
  make_set bundled a x.wav
  make_set user a y.wav z.wav
  local out
  out="$(fm list)"
  assert_contains "$out" "a (2 sounds, user)"
  assert_not_contains "$out" "a (1 sound, bundled)"
  fm play a >/dev/null
  assert_contains "$(cat "$T/played")" "$FEEDME_CONFIG_DIR/sounds/a/"
}

test_list_ignores_empty_and_non_audio() {
  mkdir -p "$FEEDME_SOUNDS_DIR/empty"
  make_set bundled docs README.md notes.txt
  make_set bundled a x.wav CREDITS.md
  local out
  out="$(fm list)"
  assert_not_contains "$out" "empty"
  assert_not_contains "$out" "docs"
  assert_contains "$out" "a (1 sound, bundled)"
}

test_set_valid() {
  make_set user mine s.WAV
  fm set mine >/dev/null || fail "set mine failed"
  assert_contains "$(fm status)" "set: mine (1 sound)"
}

test_set_unknown() {
  assert_fail fm set nope
  assert_contains "$(fm status)" "set: feedme"
}

test_set_traversal() {
  mkdir -p "$T/x" "$FEEDME_SOUNDS_DIR/a/b"
  : > "$T/x/s.wav"
  : > "$FEEDME_SOUNDS_DIR/a/b/s.wav"
  make_set bundled .hidden s.wav
  local name
  for name in ../x .hidden a/b '' '..' '-'; do
    assert_fail fm set "$name"
  done
  assert_contains "$(fm status)" "set: feedme"
  assert_not_contains "$(fm list)" "hidden"
}

test_play_spaces() {
  make_set bundled a "my sound.wav"
  fm play a >/dev/null
  assert_eq "$(cat "$T/played")" "1:$FEEDME_SOUNDS_DIR/a/my sound.wav"
}

test_no_player() {
  unset FEEDME_PLAYER
  local sys
  sys="$(path_without "${NO_PLAYERS[@]}")"
  PATH="$sys" fm play >/dev/null 2>&1 || fail "play must not fail without a player"
  assert_contains "$(PATH="$sys" fm status)" "no audio player"
}

test_player_extension_filter() {
  unset FEEDME_PLAYER
  local sys
  sys="$(path_without "${NO_PLAYERS[@]}")"
  make_tool aplay 'printf "%s\n" "$1" >> "'"$T"'/played"'
  make_set bundled a x.mp3 y.wav
  assert_contains "$(PATH="$T/bin:$sys" fm list)" "a (1 sound, bundled)"
  fm set a >/dev/null
  for _ in 1 2 3 4 5 6; do PATH="$T/bin:$sys" fm play >/dev/null; done
  assert_not_contains "$(cat "$T/played")" "x.mp3"
  assert_contains "$(cat "$T/played")" "y.wav"
}

test_missing_set_falls_back() {
  make_set user gone s.wav
  fm set gone >/dev/null
  rm -rf "$FEEDME_CONFIG_DIR/sounds/gone"
  assert_contains "$(fm status)" "set: feedme"
  fm play >/dev/null
  assert_contains "$(cat "$T/played")" "/feedme/clip.wav"
}

# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------

main() {
  local tests t pass=0 failed=""
  if [ $# -gt 0 ]; then
    tests="$*"
  else
    tests="$(declare -F | awk '{print $3}' | grep '^test_')"
  fi
  for t in $tests; do
    if ( t_setup; trap t_teardown EXIT; "$t" ); then
      pass=$((pass + 1))
      echo "ok   $t"
    else
      failed="$failed $t"
      echo "FAIL $t"
    fi
  done
  echo
  if [ -n "$failed" ]; then
    echo "$pass passed, failed:$failed"
    exit 1
  fi
  echo "$pass passed"
}

main "$@"
