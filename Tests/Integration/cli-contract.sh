#!/usr/bin/env bash
# CLI contract test. Usage: cli-contract.sh <maclang-binary>
# Everything runs against the mock engine (MACLANG_ENGINE=mock) except the doctor check,
# which must work without it. The real Translation framework is never called here.
set -euo pipefail

bin=${1:?usage: cli-contract.sh <binary>}
export MACLANG_HOME MACLANG_AUTOSTART=0
MACLANG_HOME=$(mktemp -d)
server_pid=""
cleanup() {
  [[ -n "$server_pid" ]] && kill "$server_pid" 2>/dev/null && wait "$server_pid" 2>/dev/null
  rm -rf "$MACLANG_HOME"
}
trap cleanup EXIT
port=19091

fail() { echo "FAIL: $*" >&2; exit 1; }
now_ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time()*1000'; }
expect_eq() { [[ "$2" == "$3" ]] || fail "$1: expected [$3], got [$2]"; }
mock() { MACLANG_ENGINE=mock "$@"; }
# every error ends with a `fix:` line (self-healing guide); $1 = stderr file, $2 = text the fix must contain
expect_fix() { grep -q '^fix: .*'"$2" "$1" || fail "fix line missing/wrong ($2): $(cat "$1")"; }

# --version
expect_eq "version" "$("$bin" --version)" "maclang 0.1.0"

# I-CLI-1: text / json / yaml
expect_eq "I-CLI-1 text" "$(mock "$bin" translate "hello" --from en --to ko)" "[mock en→ko] hello"
expect_eq "I-CLI-1 json" "$(mock "$bin" translate "hello" --from en --to ko --format json)" '{"translatedText":"[mock en→ko] hello"}'
expect_eq "I-CLI-1 yaml" "$(mock "$bin" translate "hello" --from en --to ko --format yaml)" 'translatedText: "[mock en→ko] hello"'
auto=$(mock "$bin" translate "Bonjour tout le monde" --to ko --format json)
[[ "$auto" == '{"translatedText":"[mock fr→ko] Bonjour tout le monde","detectedLanguage":{"confidence":'*',"language":"fr"}}' ]] \
  || fail "I-CLI-1 auto json: $auto"
expect_eq "I-CLI-1 alias zt" "$(mock "$bin" translate "x" --from en --to zt)" "[mock en→zh-TW] x"
expect_eq "I-CLI-1 languages json" "$(mock "$bin" languages --format json)" \
  '[{"code":"en","name":"English","targets":["ja","ko"]},{"code":"ko","name":"Korean","targets":["en"]}]'
expect_eq "I-CLI-1 languages --from" "$(mock "$bin" languages --from ko --format json)" \
  '[{"code":"ko","name":"Korean","targets":["en"]}]'
mock "$bin" languages | grep -q '^- code: en$' || mock "$bin" languages | grep -q 'code: en' || fail "I-CLI-1 languages yaml"
set +e
mock "$bin" translate "x" --from en --to xx >/dev/null 2>"$MACLANG_HOME/err"; rc=$?
set -e
expect_eq "I-CLI-1 unsupported exit" "$rc" "69"
grep -q 'unsupported_language' "$MACLANG_HOME/err" || fail "I-CLI-1 unsupported stderr"
expect_fix "$MACLANG_HOME/err" 'maclang languages --from'
grep -q '^field: target$' "$MACLANG_HOME/err" || fail "I-CLI-1 field echo: $(cat "$MACLANG_HOME/err")"
grep -q '^received: xx$' "$MACLANG_HOME/err" || fail "I-CLI-1 received echo"

# I-CLI-2: stdin (one trailing newline stripped)
expect_eq "I-CLI-2 stdin" "$(printf 'hello\n' | mock "$bin" translate --from en --to ko)" "[mock en→ko] hello"
expect_eq "I-CLI-2 stdin multi-line" "$(printf 'a\nb\n' | mock "$bin" translate --from en --to ko --format json)" '{"translatedText":"[mock en→ko] a\nb"}'

# I-CLI-3: empty input -> 64
for input in "" "   " $'\n'; do
  set +e; printf '%s' "$input" | mock "$bin" translate --from en --to ko >/dev/null 2>&1; rc=$?; set -e
  expect_eq "I-CLI-3 empty stdin [$input]" "$rc" "64"
done
set +e; printf '' | mock "$bin" translate --from en --to ko >/dev/null 2>"$MACLANG_HOME/err"; set -e
expect_fix "$MACLANG_HOME/err" 'maclang translate'
grep -q '^error: input text is empty (invalid_request)$' "$MACLANG_HOME/err" || fail "empty input message"
set +e; mock "$bin" translate "  " --from en --to ko >/dev/null 2>&1; rc=$?; set -e
expect_eq "I-CLI-3 blank arg" "$rc" "64"
set +e; mock "$bin" translate "x" --from en >/dev/null 2>&1; rc=$?; set -e
expect_eq "I-CLI-3 missing --to" "$rc" "64"
set +e; "$bin" bogus >/dev/null 2>&1; rc=$?; set -e
expect_eq "unknown command" "$rc" "64"

# timeout-bounds: timeouts must be finite and in (0, 86400]
for bad in 0 -1 nan inf 86401 abc; do
  set +e; mock "$bin" translate "x" --from en --to ko --timeout "$bad" >/dev/null 2>&1; rc=$?; set -e
  expect_eq "timeout-bounds --timeout $bad" "$rc" "64"
done
set +e; mock "$bin" serve --engine-timeout 0 >/dev/null 2>&1; rc=$?; set -e
expect_eq "timeout-bounds --engine-timeout 0" "$rc" "64"
expect_eq "timeout-bounds max accepted" "$(mock "$bin" translate "x" --from en --to ko --timeout 86400)" "[mock en→ko] x"
# strategy-help: the default strategy is documented
"$bin" translate --help | grep -q 'Without --strategy, maclang always requests high fidelity.' || fail "strategy-help help text"

# I-CLI-4: detect uses the real NaturalLanguage framework
expect_eq "I-CLI-4 text" "$("$bin" detect "Bonjour tout le monde")" "fr"
d=$("$bin" detect "Bonjour tout le monde" --format json)
[[ "$d" == '[{"confidence":'*',"language":"fr"}'* ]] || fail "I-CLI-4 json: $d"
set +e; "$bin" detect "12345" >/dev/null 2>&1; rc=$?; set -e
expect_eq "I-CLI-4 undetectable" "$rc" "65"

# I-CLI-9: --timeout bounds a slow engine
start=$(now_ms)
set +e; MACLANG_MOCK_DELAY_MS=3000 mock "$bin" translate "x" --from en --to ko --timeout 1 >/dev/null 2>"$MACLANG_HOME/err"; rc=$?; set -e
elapsed=$(( $(now_ms) - start ))
expect_eq "I-CLI-9 exit" "$rc" "75"
(( elapsed < 2000 )) || fail "I-CLI-9 took ${elapsed}ms"
grep -q 'timeout' "$MACLANG_HOME/err" || fail "I-CLI-9 stderr"

# I-CLI-10: doctor never touches the Translation framework outside a GUI session
session=$(/bin/launchctl managername 2>/dev/null || echo unknown)
start=$(now_ms)
set +e; out=$(env -u MACLANG_ENGINE "$bin" doctor --format json 2>"$MACLANG_HOME/err"); rc=$?; set -e
elapsed=$(( $(now_ms) - start ))
expect_eq "I-CLI-10 exit" "$rc" "0"
echo "$out" | grep -q "\"session\":\"$session\"" || fail "I-CLI-10 session: $out"
if [[ "$session" != "Aqua" ]]; then
  (( elapsed < 3000 )) || fail "I-CLI-10 took ${elapsed}ms"
  echo "$out" | grep -q '"translation"' && fail "I-CLI-10 translation key outside Aqua"
fi
echo "$out" | grep -q '"version":"0.1.0"' || fail "I-CLI-10 version"
for key in macos strategy_api engine home label bundle agent server; do
  echo "$out" | grep -q "\"$key\":" || fail "I-CLI-10 missing key $key"
done

# --- server route (mock server on 19091, config.json points the CLI at it) ---
lsof -nP -iTCP:$port -sTCP:LISTEN >/dev/null 2>&1 && fail "port $port is busy"
printf '{"host":"127.0.0.1","port":%d}' "$port" >"$MACLANG_HOME/config.json"

# I-CLI-6: no server + autostart disabled -> 75
set +e; mock "$bin" translate "x" --from en --to ko --route server >/dev/null 2>"$MACLANG_HOME/err"; rc=$?; set -e
expect_eq "I-CLI-6 exit" "$rc" "75"
grep -q session_unavailable "$MACLANG_HOME/err" || fail "I-CLI-6 stderr"
expect_fix "$MACLANG_HOME/err" 'MACLANG_AUTOSTART.*maclang service start' 

start_server() {
  for _ in $(seq 1 40); do
    MACLANG_ENGINE=mock "$bin" serve --port $port 2>"$MACLANG_HOME/server.log" &
    server_pid=$!
    for _ in $(seq 1 30); do
      curl -s -m1 "http://127.0.0.1:$port/health" >/dev/null 2>&1 && return 0
      kill -0 "$server_pid" 2>/dev/null || break
      sleep 0.1
    done
    kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; server_pid=""
    sleep 1   # a previous run's TIME_WAIT can briefly block the bind
  done
  fail "server did not start"
}
stop_server() { kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; server_pid=""; }

start_server

# I-CLI-5: --route server output == local mock output (all formats, batch-free paths)
for fmt in text json yaml; do
  local_out=$(mock "$bin" translate "Bonjour tout le monde" --to ko --format $fmt --route local)
  server_out=$(mock "$bin" translate "Bonjour tout le monde" --to ko --format $fmt --route server)
  expect_eq "I-CLI-5 translate $fmt" "$server_out" "$local_out"
  local_out=$(mock "$bin" translate "hello" --from en --to ko --format $fmt --route local)
  server_out=$(mock "$bin" translate "hello" --from en --to ko --format $fmt --route server)
  expect_eq "I-CLI-5 translate explicit $fmt" "$server_out" "$local_out"
done
for fmt in json yaml; do
  expect_eq "I-CLI-5 languages $fmt" "$(mock "$bin" languages --format $fmt --route server)" "$(mock "$bin" languages --format $fmt --route local)"
  expect_eq "I-CLI-5 languages --from $fmt" "$(mock "$bin" languages --from ko --format $fmt --route server)" "$(mock "$bin" languages --from ko --format $fmt --route local)"
done

# I-CLI-7: server error codes map to exit codes
set +e; mock "$bin" translate "x" --from en --to xx --route server >/dev/null 2>"$MACLANG_HOME/err"; rc=$?; set -e
expect_eq "I-CLI-7 exit" "$rc" "69"
grep -q 'unsupported_language' "$MACLANG_HOME/err" || fail "I-CLI-7 stderr"
expect_fix "$MACLANG_HOME/err" 'maclang languages --from'   # the server's fix is printed
grep -q '^field: target$' "$MACLANG_HOME/err" || fail "I-CLI-7 server field: $(cat "$MACLANG_HOME/err")"
grep -q '^received: xx$' "$MACLANG_HOME/err" || fail "I-CLI-7 server received"
set +e; mock "$bin" languages --from fr --route server >/dev/null 2>&1; rc=$?; set -e
expect_eq "I-CLI-7 languages unknown --from" "$rc" "69"

# oversized-body: an oversized body is answered with payload_too_large (64), not a dropped connection
python3 -I -c 'import sys; sys.stdout.write("a" * (3 * 1024 * 1024))' | mock "$bin" translate --from en --to ko --route server >/dev/null 2>"$MACLANG_HOME/err" && rc=0 || rc=$?
expect_eq "oversized-body exit" "$rc" "64"
grep -q payload_too_large "$MACLANG_HOME/err" || fail "oversized-body stderr: $(cat "$MACLANG_HOME/err")"

# undetected-source: undetectable text with --from auto translates as English with confidence 0 (local and server)
for route in local server; do
  expect_eq "undetected-source $route" "$(mock "$bin" translate "12345" --to ko --format json --route $route)" \
    '{"translatedText":"[mock en→ko] 12345","detectedLanguage":{"confidence":0,"language":"en"}}'
done

# version mismatch warning is not triggered for a matching server
mock "$bin" translate "x" --from en --to ko --route server 2>&1 >/dev/null | grep -q 'differs' && fail "unexpected version warning"
stop_server

# I-CLI-8: a slow server is bounded by --timeout
export MACLANG_MOCK_DELAY_MS=3000
start_server
unset MACLANG_MOCK_DELAY_MS
start=$(now_ms)
set +e; mock "$bin" translate "x" --from en --to ko --route server --timeout 1 >/dev/null 2>"$MACLANG_HOME/err"; rc=$?; set -e
elapsed=$(( $(now_ms) - start ))
expect_eq "I-CLI-8 exit" "$rc" "75"
(( elapsed < 2000 )) || fail "I-CLI-8 took ${elapsed}ms"
stop_server

# Another program on the port is "foreign": fail fast instead of trying to start a server.
holder_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
python3 -I "$holder_dir/port-holder.py" $port "$MACLANG_HOME/holder.err" &
foreign_pid=$!
trap 'kill "$foreign_pid" 2>/dev/null || true; cleanup' EXIT
for _ in $(seq 1 350); do lsof -nP -iTCP:$port -sTCP:LISTEN >/dev/null 2>&1 && break; sleep 0.1; done   # the helper retries the bind for up to 30 s
lsof -nP -iTCP:$port -sTCP:LISTEN >/dev/null 2>&1 || { cat "$MACLANG_HOME/holder.err" 2>/dev/null >&2; fail "could not occupy the port"; }
start=$(now_ms)
set +e; MACLANG_AUTOSTART=1 mock "$bin" translate "x" --from en --to ko --route server >/dev/null 2>"$MACLANG_HOME/err"; rc=$?; set -e
elapsed=$(( $(now_ms) - start ))
expect_eq "foreign exit" "$rc" "75"
(( elapsed < 2000 )) || fail "foreign took ${elapsed}ms"
grep -q "port 127.0.0.1:$port is in use by another program (not maclang)" "$MACLANG_HOME/err" || fail "foreign message: $(cat "$MACLANG_HOME/err")"
expect_fix "$MACLANG_HOME/err" 'maclang service install --port <free port>' 
doctor_state=$(mock "$bin" doctor --format json | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["server"]["state"])')
expect_eq "doctor server state" "$doctor_state" foreign
kill "$foreign_pid" 2>/dev/null || true; wait "$foreign_pid" 2>/dev/null || true

# uninstall-corrupt-config: `service uninstall` works with a corrupt config.json (nothing loaded, isolated label and dirs)
uhome=$(mktemp -d); uagents="$uhome/agents"; mkdir -p "$uagents"
printf '{' >"$uhome/config.json"
printf 'dummy' >"$uagents/kim.junmo.maclang.contract-test.plist"
set +e
MACLANG_HOME="$uhome" MACLANG_LABEL=kim.junmo.maclang.contract-test MACLANG_LAUNCH_AGENTS_DIR="$uagents" "$bin" service uninstall >/dev/null 2>"$MACLANG_HOME/err"; rc=$?
set -e
expect_eq "uninstall-corrupt-config exit" "$rc" "0"
[[ ! -e "$uagents/kim.junmo.maclang.contract-test.plist" ]] || fail "uninstall-corrupt-config plist still in the agents dir"
rm -rf "$uhome"

echo "ok: cli contract"
