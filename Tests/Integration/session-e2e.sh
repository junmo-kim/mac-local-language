#!/usr/bin/env bash
# Real-engine end-to-end test through the login-session server. LOCAL ONLY (needs a GUI login
# session on this Mac; excluded from CI). Usage: session-e2e.sh <maclang-binary>
#
# The CLI here may run outside the GUI session (e.g. over SSH or an agent shell); the server it
# auto-starts runs inside the session via LaunchServices. Nothing here calls the Apple engine
# in-process. Everything is isolated: temp home, label kim.junmo.maclang.e2e, port 19091.
set -euo pipefail

bin=$(cd "$(dirname "${1:?usage: session-e2e.sh <binary>}")" && pwd)/$(basename "$1")
uid=$(id -u)
port=19091
base="http://127.0.0.1:$port"
export MACLANG_HOME MACLANG_LABEL=kim.junmo.maclang.e2e MACLANG_LAUNCH_AGENTS_DIR
MACLANG_HOME=$(mktemp -d)
MACLANG_LAUNCH_AGENTS_DIR="$MACLANG_HOME/agents"
unset MACLANG_ENGINE MACLANG_AUTOSTART MACLANG_MOCK_DELAY_MS
label=$MACLANG_LABEL
helper_pids=()

fail() { echo "FAIL: $*" >&2; exit 1; }
note() { echo "note: $*"; }
now_ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time()*1000'; }
expect_eq() { [[ "$2" == "$3" ]] || fail "$1: expected [$3], got [$2]"; }
health() { curl -s --max-time 2 "$base/health"; }
health_field() { health | python3 -I -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]])' "$1"; }
has_hangul() { python3 -I -c 'import re,sys; sys.exit(0 if re.search("[가-힣]", sys.stdin.read()) else 1)'; }
loaded() { launchctl print "gui/$uid/$label" >/dev/null 2>&1; }
wait_health() { for _ in $(seq 1 "${1:-150}"); do health >/dev/null 2>&1 && return 0; sleep 0.1; done; return 1; }
wait_port_free() { for _ in $(seq 1 100); do lsof -nP -iTCP:$port -sTCP:LISTEN >/dev/null 2>&1 || return 0; sleep 0.1; done; return 1; }

cleanup() {
  set +e
  for p in "${helper_pids[@]:-}"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null; done
  "$bin" service uninstall >/dev/null 2>&1
  # Any server still running out of this test's bundle (e.g. started by auto-start).
  for p in $(pgrep -f "$MACLANG_HOME/MacLang.app" 2>/dev/null); do kill -TERM "$p" 2>/dev/null; done
  sleep 0.5
  [[ -d "$MACLANG_HOME" ]] && trash "$MACLANG_HOME" 2>/dev/null
}
trap cleanup EXIT

# --- preconditions ---------------------------------------------------------------------------
[[ "$(launchctl print "gui/$uid" 2>/dev/null | grep -c 'kim.junmo.maclang')" == 0 ]] || fail "a kim.junmo.maclang service is already loaded"
lsof -nP -iTCP:$port -sTCP:LISTEN >/dev/null 2>&1 && fail "port $port is busy"
printf '{"host":"127.0.0.1","port":%d}' "$port" >"$MACLANG_HOME/config.json"
echo "session of this shell: $(launchctl managername)"

# --- Phase 5: auto-started server ------------------------------------------------------------
# R-1: first call builds+signs the bundle, opens it in the GUI session and forwards the request.
# Observed on the dev Mac: the system's default strategy (low-latency) had no language packs while
# high-fidelity did, so an un-strategied call answers 69 not_installed. That is recorded, and the
# remaining assertions use --strategy high-fidelity so they still exercise the whole path.
strat=()
start=$(now_ms)
set +e; out=$("$bin" translate "The quick brown fox jumps over the lazy dog." --to ko 2>"$MACLANG_HOME/err"); rc=$?; set -e
if [[ $rc == 69 ]] && grep -q not_installed "$MACLANG_HOME/err"; then
  note "R-1 default strategy answered 69 not_installed ($(tr '\n' ' ' <"$MACLANG_HOME/err"))"
  [[ -n "${E2E_STRICT_DEFAULT:-}" ]] && fail "R-1 default strategy not installed"
  strat=(--strategy high-fidelity)
  out=$("$bin" translate "The quick brown fox jumps over the lazy dog." --to ko ${strat[@]+"${strat[@]}"})
elif [[ $rc != 0 ]]; then
  fail "R-1 exit $rc: $(cat "$MACLANG_HOME/err")"
fi
r1_ms=$(( $(now_ms) - start ))
echo "$out" | has_hangul || fail "R-1 no Hangul in output: $out"
codesign --verify --strict "$MACLANG_HOME/MacLang.app" || fail "R-1 bundle signature"
pid1=$(health_field pid)
expect_eq "R-1 session" "$(health_field session)" Aqua
expect_eq "R-1 label" "$(health_field label)" "$label"
echo "R-1 ok: ${r1_ms}ms -> $out"

# R-2: second call reuses the same server and is faster.
start=$(now_ms)
out2=$("$bin" translate "The quick brown fox jumps over the lazy dog." --to ko ${strat[@]+"${strat[@]}"})
r2_ms=$(( $(now_ms) - start ))
expect_eq "R-2 same pid" "$(health_field pid)" "$pid1"
echo "$out2" | has_hangul || fail "R-2 no Hangul"
(( r2_ms < r1_ms )) || fail "R-2 (${r2_ms}ms) not faster than R-1 (${r1_ms}ms)"
echo "R-2 ok: ${r2_ms}ms (pid $pid1 reused)"

# R-3: auto detection (ja, zh-Hans, and zh-Hant for the zh-TW question)
for pair in "今日はとても良い天気ですね。散歩に行きましょう。:ja" "我今天去商店买了一些苹果和香蕉，天气很好。:zh"; do
  text=${pair%:*}; want=${pair##*:}
  j=$("$bin" translate "$text" --from auto --to ko ${strat[@]+"${strat[@]}"} --format json)
  got=$(python3 -I -c 'import json,sys; print(json.load(sys.stdin)["detectedLanguage"]["language"])' <<<"$j")
  expect_eq "R-3 detected ($want)" "$got" "$want"
  python3 -I -c 'import json,sys; print(json.load(sys.stdin)["translatedText"])' <<<"$j" | has_hangul || fail "R-3 no Hangul for $want: $j"
done
trad="我今天去商店買了一些蘋果和香蕉，天氣很好。"
set +e; j=$("$bin" translate "$trad" --from auto --to ko ${strat[@]+"${strat[@]}"} --format json 2>"$MACLANG_HOME/err"); rc=$?; set -e
note "R-3 zh-TW (Traditional Chinese, --from auto --to ko): exit $rc; $( [[ $rc == 0 ]] && echo "$j" || tr '\n' ' ' <"$MACLANG_HOME/err")"
set +e; j=$("$bin" translate "$trad" --from zh-TW --to en ${strat[@]+"${strat[@]}"} --format json 2>"$MACLANG_HOME/err"); rc=$?; set -e
note "R-3 zh-TW explicit (--from zh-TW --to en): exit $rc; $( [[ $rc == 0 ]] && echo "$j" || tr '\n' ' ' <"$MACLANG_HOME/err")"
echo "R-3 ok"

# R-4: unsupported target
set +e; "$bin" translate "hello" --from en --to xx >/dev/null 2>"$MACLANG_HOME/err"; rc=$?; set -e
expect_eq "R-4 exit" "$rc" 69
echo "R-4 ok: $(tr '\n' ' ' <"$MACLANG_HOME/err")"

# R-5: language catalog for en
"$bin" languages --from en ${strat[@]+"${strat[@]}"} --format json | python3 -I -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d[0]["code"]=="en" and "ko" in d[0]["targets"] else 1)' \
  || fail "R-5 ko missing from en targets"
echo "R-5 ok"

# R-6: strategy (expected: low-latency not installed -> 69 not_installed; record what the OS does)
set +e; "$bin" translate "hello" --from en --to ko --strategy low-latency >"$MACLANG_HOME/r6.out" 2>"$MACLANG_HOME/err"; rc=$?; set -e
if [[ $rc == 69 ]] && grep -q 'not_installed' "$MACLANG_HOME/err"; then
  echo "R-6 ok: exit 69 not_installed ($(tr '\n' ' ' <"$MACLANG_HOME/err"))"
elif [[ $rc == 0 ]]; then
  echo "R-6 observed: exit 0 (low-latency IS installed): $(cat "$MACLANG_HOME/r6.out")"
else
  fail "R-6 unexpected exit $rc: $(cat "$MACLANG_HOME/err")"
fi

# R-11: detect needs no server (and no autostart)
"$bin" service stop >/dev/null || fail "stop before R-11"
wait_port_free || fail "R-11 server still up"
expect_eq "R-11 detect" "$(MACLANG_AUTOSTART=0 "$bin" detect "안녕하세요")" ko
echo "R-11 ok"

# PHASE6_MARKER
cleanup
set +e
[[ "$(launchctl print "gui/$uid" 2>/dev/null | grep -c 'maclang.e2e')" == 0 ]] || fail "launchd still lists maclang.e2e"
[[ -z "$(pgrep -f 'maclang.e2e')" ]] || fail "maclang.e2e process still running"
set -e
echo "timings: R-1 ${r1_ms}ms, R-2 ${r2_ms}ms"
echo "ok: session e2e"
