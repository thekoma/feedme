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

# skip <reason>: the test cannot run here (missing tool); reported, not failed.
SKIP=77
skip() { echo "    skipped: $*"; exit "$SKIP"; }

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

# wait_for <whole seconds> <test-expression...>  polls until the expression holds.
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

test_missing_default_falls_back_to_first_set() {
  rm -rf "$FEEDME_SOUNDS_DIR/feedme"
  make_set bundled zeta z.wav
  make_set bundled alpha a.wav
  fm set gone >/dev/null 2>&1
  assert_contains "$(fm status)" "set: alpha"
  fm play >/dev/null
  assert_contains "$(cat "$T/played")" "/alpha/a.wav"
}

test_no_sets_at_all() {
  rm -rf "$FEEDME_SOUNDS_DIR/feedme"
  assert_contains "$(fm status)" "set: none"
  assert_contains "$(fm list)" "no sound sets found"
  arm s1
  sleep 2.5
  assert_eq "$(played_count)" 0
}

test_invalid_feedme_player_reported() {
  export FEEDME_PLAYER="$T/bin/no-such-player"
  assert_contains "$(fm status)" "FEEDME_PLAYER=$T/bin/no-such-player not found"
  assert_contains "$(fm play)" "FEEDME_PLAYER=$T/bin/no-such-player not found"
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
# Alert lifecycle: arm / cancel / fire (the plugin hooks)
# ---------------------------------------------------------------------------

arm() { hook_json "$1" | FEEDME_DELAY="${2:-1}" fm arm; }
cancel() { hook_json "$1" | fm cancel; }
fire_gone() { ! fire_running; }
no_play_after() { sleep "$1"; assert_eq "$(played_count)" 0; }

test_arm_fires() {
  arm s1
  wait_for 4 has_played || fail "no sound within 4s"
  assert_contains "$(cat "$T/played")" "/feedme/clip.wav"
}

test_cancel_prevents() {
  arm s1
  cancel s1
  no_play_after 2.5
}

test_cancel_stops_fire_process() {
  arm s1 30
  wait_for 2 fire_running || fail "fire did not start"
  cancel s1
  wait_for 3 fire_gone || fail "fire still running 2s after cancel"
}

test_rearm_plays_once() {
  arm s1
  sleep 0.4
  arm s1
  wait_for 4 has_played || fail "no sound"
  sleep 1.5
  assert_eq "$(played_count)" 1
}

test_disabled_does_not_arm() {
  fm off >/dev/null
  arm s1
  [ -e "$FEEDME_STATE_DIR/s1" ] && fail "armed while disabled"
  no_play_after 2.5
}

test_off_while_waiting() {
  arm s1 2
  fm off >/dev/null
  no_play_after 3.5
}

test_sessions_isolated() {
  arm A
  arm B
  cancel A
  wait_for 4 has_played || fail "session B did not play"
  sleep 1
  assert_eq "$(played_count)" 1
}

test_missing_session_id_pairs_via_default() {
  local input
  for input in '{}' '' '{"x":' '{"session_id":""}' '{"session_id":"../.."}'; do
    printf '%s' "$input" | FEEDME_DELAY=1 fm arm
    [ -e "$FEEDME_STATE_DIR/default" ] || fail "input [$input] did not arm 'default'"
    printf '%s' "$input" | fm cancel
  done
  no_play_after 2.5
}

test_no_jq_fallback() {
  local sys
  sys="$(path_without jq)"
  printf '{"session_id":"first","tool_input":{"session_id":"second"}}' | PATH="$sys" FEEDME_DELAY=30 fm arm
  [ -e "$FEEDME_STATE_DIR/first" ] || fail "sed fallback did not use the first session_id"
  [ -e "$FEEDME_STATE_DIR/second" ] && fail "sed fallback used the last session_id"
  printf '{"session_id":"first"}' | PATH="$sys" fm cancel
  [ -e "$FEEDME_STATE_DIR/first" ] && fail "cancel without jq did not find the session"
  return 0
}

test_no_jq_malformed_input_pairs_via_default() {
  local sys input
  sys="$(path_without jq)"
  for input in '{}' '{"x":'; do
    printf '%s' "$input" | PATH="$sys" FEEDME_DELAY=1 fm arm
    [ -e "$FEEDME_STATE_DIR/default" ] || fail "no-jq input [$input] did not arm 'default'"
    printf '%s' "$input" | PATH="$sys" fm cancel
    [ -e "$FEEDME_STATE_DIR/default" ] && fail "no-jq input [$input] did not cancel 'default'"
  done
  no_play_after 2.5
}

test_hook_commands_silent_and_exit_zero() {
  local sys out
  sys="$(path_without jq)"
  : > "$T/not-a-dir"
  out="$( {
    printf '{"x":' | fm arm; echo "rc=$?"
    printf '{"x":' | fm cancel; echo "rc=$?"
    printf '{"session_id":"z"}' | PATH="$sys" fm arm; echo "rc=$?"
    printf '{"session_id":"z"}' | FEEDME_STATE_DIR="$T/not-a-dir/state" fm arm; echo "rc=$?"
    printf '{"session_id":"z"}' | FEEDME_STATE_DIR="$T/not-a-dir/state" fm cancel; echo "rc=$?"
    printf '{"session_id":"z"}' | FEEDME_CONFIG_DIR="$T/not-a-dir/config" fm arm; echo "rc=$?"
  } 2>&1 )"
  assert_eq "$out" "rc=0
rc=0
rc=0
rc=0
rc=0
rc=0"
}

test_symlinked_state_dir_refused() {
  mkdir -p "$T/elsewhere"
  ln -s "$T/elsewhere" "$FEEDME_STATE_DIR"
  arm s1
  [ -n "$(ls -A "$T/elsewhere")" ] && fail "wrote through a symlinked state dir"
  no_play_after 2.5
}

test_state_dir_is_private() {
  unset FEEDME_STATE_DIR
  export TMPDIR="$T/tmp"
  mkdir -p "$TMPDIR"
  arm s1 30
  local dir
  dir="$TMPDIR/claude-feedme-$(id -u)"
  [ -d "$dir" ] || fail "state dir not created in TMPDIR"
  # shellcheck disable=SC2012  # stat flags differ between macOS and Linux
  assert_eq "$(ls -ld "$dir" | cut -c1-10)" "drwx------"
}

test_trace_records_hooks() {
  arm s1
  cancel s1
  arm s2
  wait_for 4 has_played || fail "no sound"
  sleep 0.3
  local trace
  trace="$(cat "$T/trace")"
  assert_contains "$trace" "arm s1"
  assert_contains "$trace" "cancel s1"
  assert_contains "$trace" "fire s2"
  assert_not_contains "$trace" "fire s1"
}

# ---------------------------------------------------------------------------
# Actions: webhooks and scripts in hooks.d
# ---------------------------------------------------------------------------

HOOKS_D() { printf '%s\n' "$FEEDME_CONFIG_DIR/hooks.d"; }

# Fake curl: argv to curl.argv, stdin (the curl config) to curl.stdin,
# the --data argument to payload; answers like `-w '%{http_code}'`.
fake_curl() {
  make_tool curl '
printf "%s\n" "$*" >> "'"$T"'/curl.argv"
while [ $# -gt 0 ]; do
  if [ "$1" = "--data" ]; then printf "%s" "$2" > "'"$T"'/payload"; fi
  shift
done
cat >> "'"$T"'/curl.stdin"
printf 200'
}

add_script() {
  mkdir -p "$(HOOKS_D)"
  printf '#!/bin/bash\n%s\n' "$2" > "$(HOOKS_D)/$1"
  chmod +x "$(HOOKS_D)/$1"
}

has_file() { [ -e "$1" ]; }

test_hook_add_writes_private_file() {
  fm hook add ha 'https://h.example/api/webhook/secret123' 'Authorization: Bearer tok' >/dev/null || fail "add failed"
  local file
  file="$(HOOKS_D)/ha.webhook"
  [ -f "$file" ] || fail "no webhook file"
  # shellcheck disable=SC2012  # stat flags differ between macOS and Linux
  assert_eq "$(ls -l "$file" | cut -c1-10)" "-rw-------"
  # shellcheck disable=SC2012
  assert_eq "$(ls -ld "$(HOOKS_D)" | cut -c1-10)" "drwx------"
  assert_contains "$(cat "$file")" "url=https://h.example/api/webhook/secret123"
  assert_contains "$(cat "$file")" "header=Authorization: Bearer tok"
}

test_hook_add_validates() {
  assert_fail fm hook add ../x https://a.example
  assert_fail fm hook add .x https://a.example
  assert_fail fm hook add ok ftp://a.example
  assert_fail fm hook add ok 'https://a.example/x y'
  assert_fail fm hook add ok https://a.example 'NoColon'
  assert_fail fm hook add ok https://a.example 'Bad Name: x'
  assert_fail fm hook add ok https://a.example 'X-Empty:   '
  assert_fail fm hook add ok https://a.example "X-Inject: a
url=https://evil.example"
  assert_fail fm hook add ok
  [ -n "$(ls -A "$(HOOKS_D)" 2>/dev/null)" ] && fail "a rejected webhook was written"
  return 0
}

test_hook_add_and_list_mask_secrets() {
  local out
  out="$(fm hook add ha 'https://user:pw@h.example:8123/api/webhook/secret123?k=v' 'Authorization: Bearer tok')"
  assert_contains "$out" "https://h.example:8123/***"
  assert_contains "$out" "characters"
  out="$out
$(fm hook list)"
  assert_contains "$out" "ha"
  assert_contains "$out" "https://h.example:8123/***"
  assert_contains "$out" "Authorization: ***"
  assert_not_contains "$out" "secret123"
  assert_not_contains "$out" "tok"
  assert_not_contains "$out" "pw@"
}

test_hook_rm() {
  fm hook add ha https://h.example/x >/dev/null
  fm hook rm ha >/dev/null || fail "rm failed"
  [ -e "$(HOOKS_D)/ha.webhook" ] && fail "file still there"
  assert_fail fm hook rm ha
}

test_fire_calls_webhook() {
  fake_curl
  fm hook add ha 'https://h.example/hook?a=1&b=2' 'X-Token: abc' >/dev/null
  PATH="$T/bin:$PATH" arm s1
  wait_for 4 has_file "$T/payload" || fail "webhook not called"
  sleep 0.2
  assert_contains "$(cat "$T/curl.stdin")" 'url = "https://h.example/hook?a=1&b=2"'
  assert_contains "$(cat "$T/curl.stdin")" 'header = "X-Token: abc"'
  assert_contains "$(cat "$T/curl.stdin")" 'header = "Content-Type: application/json"'
  assert_not_contains "$(cat "$T/curl.argv")" "abc"
  assert_contains "$(cat "$T/payload")" '"set":"feedme"'
  assert_contains "$(cat "$T/payload")" '"session_id":"s1"'
  wait_for 2 has_played || fail "sound did not play"
}

test_webhook_json_escaping() {
  command -v jq >/dev/null || skip "needs jq"
  fake_curl
  fm hook add ha https://h.example/x >/dev/null
  printf '{"session_id":"s1","cwd":"/a\\"b\\\\c\\nd\\te"}' | PATH="$T/bin:$PATH" FEEDME_DELAY=1 fm arm
  wait_for 4 has_file "$T/payload" || fail "webhook not called"
  sleep 0.2
  jq -e . "$T/payload" >/dev/null || fail "invalid JSON: $(cat "$T/payload")"
  assert_eq "$(jq -r .cwd "$T/payload")" "$(printf '/a"b\\c\nd\te')"
  assert_eq "$(jq -r .event "$T/payload")" "feedme"
}

test_fire_runs_script() {
  add_script notify 'printf "%s|%s|%s|%s" "$FEEDME_SET" "$FEEDME_SESSION_ID" "$FEEDME_CWD" "${FEEDME_SOUND##*/}" > "'"$T"'/script.out"'
  arm s1
  wait_for 4 has_file "$T/script.out" || fail "script did not run"
  sleep 0.2
  assert_eq "$(cat "$T/script.out")" "feedme|s1|/work|clip.wav"
}

test_non_executable_files_ignored() {
  mkdir -p "$(HOOKS_D)"
  printf '#!/bin/bash\ntouch "%s/ran"\n' "$T" > "$(HOOKS_D)/README"
  arm s1
  wait_for 4 has_played || fail "no sound"
  sleep 0.5
  [ -e "$T/ran" ] && fail "a non-executable file was run"
  assert_not_contains "$(fm hook list)" "README"
}

test_failing_script_does_not_block_sound() {
  add_script broken 'exit 1'
  arm s1
  wait_for 4 has_played || fail "sound did not play"
}

script_running() { pgrep -f -- "$(HOOKS_D)/$1" >/dev/null; }

test_hanging_script_is_killed() {
  add_script slow 'sleep 3; touch "'"$T"'/late"'
  hook_json s1 | FEEDME_DELAY=1 FEEDME_ACTION_TIMEOUT=1 fm arm
  wait_for 3 has_played || fail "a hanging script delayed the sound"
  wait_for 4 fire_gone || fail "fire still waiting on the hanging script"
  script_running slow && fail "the hanging script is still running after the timeout"
  sleep 3
  [ -e "$T/late" ] && fail "the hanging script was not killed"
  return 0
}

test_hanging_grandchildren_are_killed() {
  # The trailing `true` stops bash from exec-ing sh, so sh is a grandchild.
  add_script nested '( sh -c "sleep 3; touch '"$T"'/late"; true ) & wait'
  local started
  started="$(date +%s)"
  FEEDME_ACTION_TIMEOUT=1 fm hook test nested >/dev/null
  [ $(( $(date +%s) - started )) -le 2 ] || fail "hook test waited for the hanging script"
  sleep 3.5
  [ -e "$T/late" ] && fail "a grandchild of the script survived the timeout"
  return 0
}

test_webhook_ignores_curlrc() {
  fake_curl
  fm hook add ha https://h.example/x >/dev/null
  PATH="$T/bin:$PATH" fm hook test ha >/dev/null
  case "$(head -n 1 "$T/curl.argv")" in -q\ *) ;; *) fail "curl must get -q first: $(head -n 1 "$T/curl.argv")" ;; esac
}

test_hook_test_runs_one_or_all() {
  add_script a 'touch "'"$T"'/a.ran"'
  add_script b 'touch "'"$T"'/b.ran"'
  local out
  out="$(fm hook test a)"
  assert_contains "$out" "a"
  [ -e "$T/a.ran" ] || fail "a did not run"
  [ -e "$T/b.ran" ] && fail "b ran but only a was asked"
  fm hook test >/dev/null
  [ -e "$T/b.ran" ] || fail "b did not run"
  assert_fail fm hook test nope
  assert_eq "$(played_count)" 0
}

test_hook_test_webhook_reports_status() {
  fake_curl
  fm hook add ha https://h.example/x >/dev/null
  assert_contains "$(PATH="$T/bin:$PATH" fm hook test ha)" "HTTP 200"
}

test_status_counts_actions() {
  add_script a 'true'
  fm hook add ha https://h.example/x >/dev/null
  assert_contains "$(fm status)" "actions: 2 (a, ha)"
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
  local skipped=0 status
  for t in $tests; do
    ( t_setup; trap t_teardown EXIT; "$t" )
    status=$?
    if [ "$status" -eq 0 ]; then
      pass=$((pass + 1))
      echo "ok   $t"
    elif [ "$status" -eq "$SKIP" ]; then
      skipped=$((skipped + 1))
      echo "skip $t"
    else
      failed="$failed $t"
      echo "FAIL $t"
    fi
  done
  echo
  if [ -n "$failed" ]; then
    echo "$pass passed, $skipped skipped, failed:$failed"
    exit 1
  fi
  echo "$pass passed, $skipped skipped"
}

main "$@"
