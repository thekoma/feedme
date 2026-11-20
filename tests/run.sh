#!/bin/bash
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
  make_tool fakeplay 'printf "%s\n" "$*" >> "'"$T"'/played"'
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
  # shellcheck disable=SC2016  # the $(...) must reach the file unexpanded
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
