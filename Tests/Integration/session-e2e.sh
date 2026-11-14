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
[[ "$(launchctl print "gui/$uid" 2>/dev/null | grep -c "$label")" == 0 ]] || fail "the e2e service $label is already loaded"
lsof -nP -iTCP:$port -sTCP:LISTEN >/dev/null 2>&1 && fail "port $port is busy"
# A previous test's connections can leave the port in TIME_WAIT (~30s); the server binds without
# SO_REUSEADDR, so wait until a plain bind works.
python3 -I - "$port" <<'PY' || fail "port $port cannot be bound"
import socket, sys, time
for _ in range(60):
    s = socket.socket()
    try:
        s.bind(("127.0.0.1", int(sys.argv[1]))); s.close(); sys.exit(0)
    except OSError:
        s.close(); time.sleep(1)
sys.exit(1)
PY
printf '{"host":"127.0.0.1","port":%d}' "$port" >"$MACLANG_HOME/config.json"
echo "session of this shell: $(launchctl managername)"

# --- Phase 5: auto-started server ------------------------------------------------------------
# R-1: first call builds+signs the bundle, opens it in the GUI session and forwards the request.
# No --strategy: the engine must resolve the system's preferred strategy itself (E-STR).
strat=()
start=$(now_ms)
set +e; out=$("$bin" translate "The quick brown fox jumps over the lazy dog." --to ko 2>"$MACLANG_HOME/err"); rc=$?; set -e
[[ $rc == 0 ]] || fail "R-1 exit $rc: $(cat "$MACLANG_HOME/err")"
r1_ms=$(( $(now_ms) - start ))
echo "$out" | has_hangul || fail "R-1 no Hangul in output: $out"
codesign --verify --strict "$MACLANG_HOME/MacLang.app" || fail "R-1 bundle signature"
pid1=$(health_field pid)
expect_eq "R-1 session" "$(health_field session)" Aqua
expect_eq "R-1 label" "$(health_field label)" "$label"
# The catalog warm-up (~16 s) must not delay the first translation (it once took 18.5 s).
(( r1_ms < 10000 )) || fail "R-1 took ${r1_ms}ms (>= 10000ms): first translation waited on something"
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

# install-over-running: `service install` with an auto-started (non-agent) server running and a changed executable.
# The server must be stopped BEFORE the bundle is rebuilt, and /health must then show the new bundle.
cp -p "$bin" "$MACLANG_HOME/maclang-copy"
touch "$MACLANG_HOME/maclang-copy"
copy_mtime=$(stat -f %m "$MACLANG_HOME/maclang-copy")
health >/dev/null 2>&1 || fail "install-over-running precondition: auto-started server not running"
"$MACLANG_HOME/maclang-copy" service install --port $port >/dev/null 2>"$MACLANG_HOME/install.err" \
  || fail "install-over-running install over a running auto-started server failed: $(cat "$MACLANG_HOME/install.err")"
wait_health 50 || fail "install-over-running health after install"
real() { python3 -I -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"; }
expect_eq "install-over-running executable" "$(real "$(health_field executable)")" "$(real "$MACLANG_HOME/MacLang.app/Contents/MacOS/maclang")"
python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d["mtime"]==int(sys.argv[2]) else 1)' "$MACLANG_HOME/bundle-stamp" "$copy_mtime" \
  || fail "install-over-running bundle was not rebuilt from the changed executable"
grep -q 'launchd-managed' "$MACLANG_HOME/logs/server.log" || fail "install-over-running agent-run server does not see XPC_SERVICE_NAME == label"
"$bin" service uninstall >/dev/null || fail "install-over-running uninstall"
wait_port_free || fail "install-over-running port after uninstall"
echo "install-over-running ok"

# R-11: detect needs no server (and no autostart)
"$bin" service stop >/dev/null || fail "stop before R-11"
wait_port_free || fail "R-11 server still up"
expect_eq "R-11 detect" "$(MACLANG_AUTOSTART=0 "$bin" detect "안녕하세요")" ko
echo "R-11 ok"

# --- Phase 6: LaunchAgent service ------------------------------------------------------------
# R-7: install from a non-GUI shell goes through the bootstrap-request handshake with the app.
"$bin" service install --port $port >"$MACLANG_HOME/install.out" 2>"$MACLANG_HOME/install.err" \
  || fail "R-7 install failed: $(cat "$MACLANG_HOME/install.err")"
print_out=$(launchctl print "gui/$uid/$label")
grep -q 'state = running' <<<"$print_out" || fail "R-7 agent not running"
wait_health 50 || fail "R-7 health"
expect_eq "R-7 session" "$(health_field session)" Aqua
"$bin" service status --format json | python3 -I -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d["loaded"] is True and d["installed"] is True and d["server"]["reachable"] is True else 1)' \
  || fail "R-7 status"
[[ -f "$MACLANG_LAUNCH_AGENTS_DIR/$label.plist" ]] || fail "R-7 plist missing"
[[ ! -e "$MACLANG_HOME/bootstrap-request" && ! -e "$MACLANG_HOME/bootstrap-result" ]] || fail "R-7 handshake files left behind"
echo "R-7 ok (pid $(health_field pid))"

# install-validation: an install that fails validation (new port held by another program) changes nothing.
pid_before=$(health_field pid)
python3 -I -m http.server 19092 --bind 127.0.0.1 >/dev/null 2>&1 &
py2=$!; helper_pids+=("$py2")
for _ in $(seq 1 50); do lsof -nP -iTCP:19092 -sTCP:LISTEN >/dev/null 2>&1 && break; sleep 0.1; done
set +e; "$bin" service install --port 19092 >/dev/null 2>"$MACLANG_HOME/err"; rc=$?; set -e
expect_eq "install-validation exit" "$rc" 75
grep -q 'in use by another program' "$MACLANG_HOME/err" || fail "install-validation message: $(cat "$MACLANG_HOME/err")"
loaded || fail "install-validation the original agent is no longer loaded"
expect_eq "install-validation same pid on 19091" "$(health_field pid)" "$pid_before"
grep -q '"port":19091' "$MACLANG_HOME/config.json" || grep -q '"port" *: *19091' "$MACLANG_HOME/config.json" || fail "install-validation config changed: $(cat "$MACLANG_HOME/config.json")"
kill "$py2" 2>/dev/null || true; wait "$py2" 2>/dev/null || true
echo "install-validation ok (agent untouched, pid $pid_before)"

# R-8: stop is a clean exit, so KeepAlive(SuccessfulExit=false) must not restart it; start kickstarts.
"$bin" service stop >/dev/null || fail "R-8 stop"
wait_port_free || fail "R-8 port still bound"
sleep 12
launchctl print "gui/$uid/$label" >"$MACLANG_HOME/print.out" 2>&1
grep -q 'state = not running' "$MACLANG_HOME/print.out" || fail "R-8 restarted after stop: $(grep 'state =' "$MACLANG_HOME/print.out" | head -1)"
grep -q 'last exit code = 0' "$MACLANG_HOME/print.out" || fail "R-8 last exit code: $(grep 'last exit code' "$MACLANG_HOME/print.out")"
health >/dev/null 2>&1 && fail "R-8 server came back"
# autostart-under-launchd: with the agent loaded, a CLI call that finds no server restarts it UNDER launchd.
out=$("$bin" translate "hello" --from en --to ko) || fail "autostart-under-launchd translate after stop"
launchctl print "gui/$uid/$label" >"$MACLANG_HOME/print.out" 2>&1
grep -q 'state = running' "$MACLANG_HOME/print.out" || fail "autostart-under-launchd agent not running after CLI auto-start"
launchd_pid=$(grep -E '^\s+pid = ' "$MACLANG_HOME/print.out" | head -1 | sed 's/.*= //')
expect_eq "autostart-under-launchd health pid == launchd pid" "$(health_field pid)" "$launchd_pid"
echo "autostart-under-launchd ok (pid $launchd_pid under launchd)"
"$bin" service start >/dev/null || fail "R-8 start"
wait_health 150 || fail "R-8 health after start"
echo "R-8 ok"

# R-9: a crash is restarted by launchd (ThrottleInterval 10s)
old=$(health_field pid)
kill -9 "$old"
new=""
for _ in $(seq 1 200); do
  new=$(health_field pid 2>/dev/null || true)
  [[ -n "$new" && "$new" != "$old" ]] && break
  sleep 0.1
done
[[ -n "$new" && "$new" != "$old" ]] || fail "R-9 no restart within 20s"
echo "R-9 ok ($old -> $new)"

# R-10: uninstall unloads, moves the plist to the Trash and frees the port
"$bin" service uninstall >/dev/null || fail "R-10 uninstall"
if launchctl print "gui/$uid/$label" >"$MACLANG_HOME/print.out" 2>&1; then fail "R-10 still loaded"; fi
grep -q 'Could not find service' "$MACLANG_HOME/print.out" || fail "R-10 print: $(head -1 "$MACLANG_HOME/print.out")"
[[ ! -e "$MACLANG_LAUNCH_AGENTS_DIR/$label.plist" ]] || fail "R-10 plist still in place"
wait_port_free || fail "R-10 port still bound"
echo "R-10 ok (trash holds: $(ls "$HOME/.Trash" 2>/dev/null | grep -c "$label") item(s) matching the label)"

# R-12: stop refuses to kill anything that is not this install's own server
cat >"$MACLANG_HOME/fake.py" <<PY
import http.server, json, os, sys
claimed = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = json.dumps({"status": "ok", "version": "0.1.0", "pid": os.getpid(), "session": "Aqua",
                           "engine": "fake", "label": "fake", "executable": claimed}).encode()
        self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", $port), H).serve_forever()
PY
bundle_exe="$MACLANG_HOME/MacLang.app/Contents/MacOS/maclang"
for claimed in /usr/bin/python3 "$bundle_exe"; do
  python3 -I "$MACLANG_HOME/fake.py" "$claimed" >/dev/null 2>&1 &
  fake=$!; helper_pids+=("$fake")
  wait_health 50 || fail "R-12 fake server did not start"
  set +e; "$bin" service stop >/dev/null 2>"$MACLANG_HOME/err"; rc=$?; set -e
  expect_eq "R-12 exit (claims $claimed)" "$rc" 1
  kill -0 "$fake" 2>/dev/null || fail "R-12 the fake server was killed (claims $claimed)"
  kill "$fake"; wait "$fake" 2>/dev/null || true
  wait_port_free || fail "R-12 port"
done
echo "R-12 ok"

cleanup
set +e
[[ "$(launchctl print "gui/$uid" 2>/dev/null | grep -c 'maclang.e2e')" == 0 ]] || fail "launchd still lists maclang.e2e"
[[ -z "$(pgrep -f 'maclang.e2e')" ]] || fail "maclang.e2e process still running"
set -e
echo "timings: R-1 ${r1_ms}ms, R-2 ${r2_ms}ms"
echo "ok: session e2e"
