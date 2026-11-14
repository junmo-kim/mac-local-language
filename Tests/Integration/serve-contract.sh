#!/usr/bin/env bash
# HTTP server contract test. Usage: serve-contract.sh <maclang-binary>
# Uses the mock engine on 127.0.0.1:19091. Every process started here is killed on exit.
set -euo pipefail

bin=${1:?usage: serve-contract.sh <binary>}
port=19091
base="http://127.0.0.1:$port"
work=$(mktemp -d)
export MACLANG_HOME="$work/home"
pids=()

cleanup() {
  for p in "${pids[@]:-}"; do
    [[ -n "$p" ]] && kill "$p" 2>/dev/null || true
  done
  for p in "${pids[@]:-}"; do
    [[ -n "$p" ]] && wait "$p" 2>/dev/null || true
  done
  rm -rf "$work"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
now_ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time()*1000'; }
expect_eq() { [[ "$2" == "$3" ]] || fail "$1: expected [$3], got [$2]"; }
listening() { lsof -nP -iTCP:$port -sTCP:LISTEN >/dev/null 2>&1; }
json_get() { python3 -I -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))' "$1"; }

# curl wrapper: prints "<status>\n<body>"
req() { curl -s --max-time 10 -w '\n%{http_code}' "$@"; }
body_of() { sed '$d' <<<"$1"; }
status_of() { tail -n 1 <<<"$1"; }

listening && fail "port $port is already in use"

wait_health() {
  for _ in $(seq 1 30); do
    curl -s --max-time 1 "$base/health" >/dev/null 2>&1 && return 0
    sleep 0.1
  done
  return 1
}

# Start a mock server on $port; sets $started_pid. A previous run's connections can leave the
# port in TIME_WAIT for up to ~30s (Network.framework binds without SO_REUSEADDR here), so a
# failed bind with nobody listening is retried.
started_pid=""
start_server() {
  local log=$1
  for _ in $(seq 1 40); do
    MACLANG_ENGINE=mock "$bin" serve --port $port ${server_args:-} 2>"$log" &
    started_pid=$!
    pids+=("$started_pid")
    if wait_health; then return 0; fi
    kill "$started_pid" 2>/dev/null || true
    wait "$started_pid" 2>/dev/null || true
    sleep 1
  done
  cat "$log" >&2
  fail "server did not become healthy"
}

start_server "$work/server.log"
server_pid=$started_pid

# I-SRV-1: health fields
h=$(curl -s "$base/health")
expect_eq "I-SRV-1 status" "$(json_get 'd["status"]' <<<"$h")" ok
expect_eq "I-SRV-1 version" "$(json_get 'd["version"]' <<<"$h")" 0.1.0
expect_eq "I-SRV-1 pid" "$(json_get 'd["pid"]' <<<"$h")" "$server_pid"
expect_eq "I-SRV-1 engine" "$(json_get 'd["engine"]' <<<"$h")" mock
expect_eq "I-SRV-1 label" "$(json_get 'd["label"]' <<<"$h")" kim.junmo.maclang
expect_eq "I-SRV-1 keys" "$(json_get 'sorted(d)' <<<"$h")" "['engine', 'executable', 'label', 'pid', 'session', 'status', 'version']"
expect_eq "I-SRV-1 session" "$(json_get 'd["session"]' <<<"$h")" "$(/bin/launchctl managername 2>/dev/null || echo unknown)"
case "$(json_get 'd["executable"]' <<<"$h")" in /*maclang) ;; *) fail "I-SRV-1 executable: $h" ;; esac
grep -q 'listening on 127.0.0.1:19091' "$work/server.log" || fail "I-SRV-1 listening log"

# I-SRV-2: JSON translate (explicit source: no detectedLanguage; auto: detectedLanguage)
r=$(req -H 'Content-Type: application/json' -d '{"q":"hello","source":"en","target":"ko"}' "$base/translate")
expect_eq "I-SRV-2 status" "$(status_of "$r")" 200
expect_eq "I-SRV-2 body" "$(body_of "$r")" '{"translatedText":"[mock en→ko] hello"}'
r=$(req -H 'Content-Type: application/json' -d '{"q":"Bonjour tout le monde","source":"auto","target":"ko","alternatives":1}' "$base/translate")
b=$(body_of "$r")
expect_eq "I-SRV-2 auto text" "$(json_get 'd["translatedText"]' <<<"$b")" "[mock fr→ko] Bonjour tout le monde"
expect_eq "I-SRV-2 auto lang" "$(json_get 'd["detectedLanguage"]["language"]' <<<"$b")" fr
expect_eq "I-SRV-2 alternatives" "$(json_get 'd["alternatives"]' <<<"$b")" "[]"
# CLI --format json is byte-identical to the HTTP body
cli=$(MACLANG_ENGINE=mock "$bin" translate "hello" --from en --to ko --format json)
expect_eq "I-SRV-2 cli==http" "$cli" '{"translatedText":"[mock en→ko] hello"}'
r=$(req -H 'Content-Type: application/json' -d '{"q":"hello","source":"en","target":"ko"}' "$base/translate")
expect_eq "I-SRV-2 cli==http bytes" "$(body_of "$r")" "$cli"

# I-SRV-3: form body
r=$(req -d 'q=hello+world&source=en&target=ko' "$base/translate")
expect_eq "I-SRV-3 status" "$(status_of "$r")" 200
expect_eq "I-SRV-3 body" "$(body_of "$r")" '{"translatedText":"[mock en→ko] hello world"}'

# I-SRV-4: batch of 3
r=$(req -H 'Content-Type: application/json' -d '{"q":["a","b","c"],"source":"en","target":"ko"}' "$base/translate")
expect_eq "I-SRV-4 body" "$(body_of "$r")" '{"translatedText":["[mock en→ko] a","[mock en→ko] b","[mock en→ko] c"]}'

# I-SRV-5: detect
r=$(req -H 'Content-Type: application/json' -d '{"q":"Bonjour tout le monde"}' "$base/detect")
expect_eq "I-SRV-5 status" "$(status_of "$r")" 200
b=$(body_of "$r")
expect_eq "I-SRV-5 top" "$(json_get 'd[0]["language"]' <<<"$b")" fr
expect_eq "I-SRV-5 max 3" "$(json_get 'len(d) <= 3' <<<"$b")" True

# I-SRV-6: languages
r=$(req "$base/languages")
expect_eq "I-SRV-6 status" "$(status_of "$r")" 200
expect_eq "I-SRV-6 body" "$(body_of "$r")" '[{"code":"en","name":"English","targets":["ja","ko"]},{"code":"ko","name":"Korean","targets":["en"]}]'
r=$(req "$base/languages?strategy=low-latency")
expect_eq "I-SRV-6 strategy" "$(status_of "$r")" 200
r=$(req "$base/languages?strategy=bogus")
expect_eq "I-SRV-6 bad strategy" "$(status_of "$r")" 400

# I-SRV-7: errors
r=$(req -H 'Content-Type: application/json' -d '{"source":"en","target":"ko"}' "$base/translate")
expect_eq "I-SRV-7 q missing status" "$(status_of "$r")" 400
expect_eq "I-SRV-7 q missing code" "$(json_get 'd["code"]' <<<"$(body_of "$r")")" invalid_request
expect_eq "I-SRV-7 q missing key order" "$(json_get 'list(d)' <<<"$(body_of "$r")")" "['error', 'code', 'fix', 'field']"
json_get '"source" in d["fix"] and d["field"] == "q"' <<<"$(body_of "$r")" | grep -q True || fail "I-SRV-7 q missing fix/field: $(body_of "$r")"
json_get '"error" in d' <<<"$(body_of "$r")" | grep -q True || fail "I-SRV-7 error field"
r=$(req -d 'q=hello&source=en&target=xx' "$base/translate")
expect_eq "I-SRV-7 xx status" "$(status_of "$r")" 400
expect_eq "I-SRV-7 xx code" "$(json_get 'd["code"]' <<<"$(body_of "$r")")" unsupported_language
expect_eq "I-SRV-7 xx echo" "$(json_get '[d["field"], d["received"], "languages" in d["fix"]]' <<<"$(body_of "$r")")" "['target', 'xx', True]"
r=$(req -H 'Content-Type: application/json' -d '{"q":"x","source":"en","target":"ko","format":"html"}' "$base/translate")
expect_eq "I-SRV-7 html" "$(status_of "$r")" 400
r=$(req -H 'Content-Type: application/json' -d 'not json' "$base/translate")
expect_eq "I-SRV-7 bad json" "$(status_of "$r")" 400
r=$(req "$base/nope")
expect_eq "I-SRV-7 404 status" "$(status_of "$r")" 404
expect_eq "I-SRV-7 404 code" "$(json_get 'd["code"]' <<<"$(body_of "$r")")" not_found
expect_eq "I-SRV-7 404 fix" "$(json_get '[d["fix"], d["field"], d["received"]]' <<<"$(body_of "$r")")" "['use GET /health, POST /translate, POST /detect or GET /languages', 'path', '/nope']"
r=$(req "$base/translate")
expect_eq "I-SRV-7 405 status" "$(status_of "$r")" 405
expect_eq "I-SRV-7 405 code" "$(json_get 'd["code"]' <<<"$(body_of "$r")")" method_not_allowed
expect_eq "I-SRV-7 405 fix" "$(json_get '[d["fix"], d["received"]]' <<<"$(body_of "$r")")" "['use POST /translate', 'GET']"
r=$(req -X POST "$base/health")
expect_eq "I-SRV-7 405 health" "$(status_of "$r")" 405
big="$work/big.json"
python3 -I -c 'import sys; sys.stdout.write("{\"q\":\"" + "a"*(1100*1024) + "\",\"source\":\"en\",\"target\":\"ko\"}")' >"$big"
r=$(req -H 'Content-Type: application/json' --data-binary "@$big" "$base/translate")
expect_eq "I-SRV-7 413 status" "$(status_of "$r")" 413
expect_eq "I-SRV-7 413 code" "$(json_get 'd["code"]' <<<"$(body_of "$r")")" payload_too_large
json_get '"1024 KiB" in d["fix"] and "--max-body-kib" in d["fix"]' <<<"$(body_of "$r")" | grep -q True || fail "I-SRV-7 413 fix: $(body_of "$r")"
# form-decoding: chunked bodies and POSTs without Content-Length are rejected with a clear 400
r=$(printf '{"q":"x","source":"en","target":"ko"}' | req -H 'Content-Type: application/json' -H 'Transfer-Encoding: chunked' --data-binary @- "$base/translate")
expect_eq "I-SRV-7 chunked status" "$(status_of "$r")" 400
expect_eq "I-SRV-7 chunked code" "$(json_get 'd["code"]' <<<"$(body_of "$r")")" invalid_request
json_get '"Content-Length" in d["error"]' <<<"$(body_of "$r")" | grep -q True || fail "I-SRV-7 chunked message: $r"
raw=$(python3 -I - $port <<'PY'
import socket, sys
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])))
s.sendall(b"POST /translate HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\n\r\n")
data = b""
while True:
    chunk = s.recv(4096)
    if not chunk: break
    data += chunk
print(data.decode().split("\r\n")[0])
PY
)
expect_eq "I-SRV-7 no Content-Length" "$raw" "HTTP/1.1 400 Bad Request"
raw=$(python3 -I - $port <<'PY'
import socket, sys
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])))
s.sendall(b"POST /translate HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\n\r\n{\"q\":\"x\",\"source\":\"en\",\"target\":\"ko\"}")
data = b""
while True:
    chunk = s.recv(4096)
    if not chunk: break
    data += chunk
print(data.decode().split("\r\n\r\n", 1)[1])
PY
)
json_get '"Content-Length" in d["error"]' <<<"$raw" | grep -q True || fail "I-SRV-7 body without Content-Length: $raw"
# form-decoding: a malformed percent escape in a form body keeps the text
r=$(req -d 'q=100%+off&source=en&target=ko' "$base/translate")
expect_eq "I-SRV-3 bad escape" "$(body_of "$r")" '{"translatedText":"[mock en→ko] 100% off"}'
# undetected-source: undetectable text with source=auto is English with confidence 0 (LibreTranslate parity), per item in batches
r=$(req -H 'Content-Type: application/json' -d '{"q":"12345","source":"auto","target":"ko"}' "$base/translate")
expect_eq "undetected-source status" "$(status_of "$r")" 200
expect_eq "undetected-source body" "$(body_of "$r")" '{"translatedText":"[mock en→ko] 12345","detectedLanguage":{"confidence":0,"language":"en"}}'
r=$(req -H 'Content-Type: application/json' -d '{"q":["Bonjour tout le monde","12345"],"source":"auto","target":"ko"}' "$base/translate")
expect_eq "undetected-source batch langs" "$(json_get '[x["language"] for x in d["detectedLanguage"]]' <<<"$(body_of "$r")")" "['fr', 'en']"
expect_eq "undetected-source batch conf0" "$(json_get 'd["detectedLanguage"][1]["confidence"]' <<<"$(body_of "$r")")" "0"
# /detect keeps unable_to_detect
r=$(req -H 'Content-Type: application/json' -d '{"q":"12345"}' "$base/detect")
expect_eq "undetected-source detect status" "$(status_of "$r")" 400
expect_eq "undetected-source detect code" "$(json_get 'd["code"]' <<<"$(body_of "$r")")" unable_to_detect
# the server survives all of that
expect_eq "I-SRV-7 alive" "$(json_get 'd["status"]' <<<"$(curl -s "$base/health")")" ok

# Privacy: logs never contain request text or translations
curl -s -H 'Content-Type: application/json' -d '{"q":"sekrit-text-xyz","source":"en","target":"ko"}' "$base/translate" >/dev/null
if grep -q 'sekrit-text-xyz' "$work/server.log"; then fail "log leaked request text"; fi
grep -q 'POST /translate' "$work/server.log" || fail "request log line missing"

# I-SRV-9: a second serve on the same port exits 0 immediately (already running)
start=$(now_ms)
set +e; MACLANG_ENGINE=mock "$bin" serve --port $port 2>"$work/second.log"; rc=$?; set -e
elapsed=$(( $(now_ms) - start ))
expect_eq "I-SRV-9 exit" "$rc" 0
(( elapsed < 3000 )) || fail "I-SRV-9 took ${elapsed}ms"
grep -q 'already running' "$work/second.log" || fail "I-SRV-9 log"
kill -0 "$server_pid" 2>/dev/null || fail "I-SRV-9 original server died"

# I-SRV-8: SIGTERM -> exit 0 and the port is released
kill -TERM "$server_pid"
set +e; wait "$server_pid"; rc=$?; set -e
expect_eq "I-SRV-8 exit" "$rc" 0
for _ in $(seq 1 30); do listening || break; sleep 0.1; done
listening && fail "I-SRV-8 port still bound"

# SIGINT behaves the same
start_server "$work/int.log"
int_pid=$started_pid
kill -INT "$int_pid"
set +e; wait "$int_pid"; rc=$?; set -e
expect_eq "I-SRV-8 SIGINT exit" "$rc" 0

# Engine calls are serialized (3 concurrent 400ms calls take >= 1.2s) and bounded by --engine-timeout
export MACLANG_MOCK_DELAY_MS=400
start_server "$work/slow.log"
slow_pid=$started_pid
start=$(now_ms)
for i in 1 2 3; do
  curl -s -o /dev/null -H 'Content-Type: application/json' -d '{"q":"x","source":"en","target":"ko"}' "$base/translate" &
done
wait_jobs=$(jobs -p | grep -v "^$slow_pid$" || true)
for j in $wait_jobs; do wait "$j" 2>/dev/null || true; done
elapsed=$(( $(now_ms) - start ))
(( elapsed >= 1150 )) || fail "engine calls were not serialized (${elapsed}ms)"
kill -TERM "$slow_pid"; wait "$slow_pid" 2>/dev/null || true
unset MACLANG_MOCK_DELAY_MS

export MACLANG_MOCK_DELAY_MS=3000
server_args="--engine-timeout 1"
start_server "$work/timeout.log"
to_pid=$started_pid
server_args=""
start=$(now_ms)
r=$(req -H 'Content-Type: application/json' -d '{"q":"x","source":"en","target":"ko"}' "$base/translate")
elapsed=$(( $(now_ms) - start ))
expect_eq "engine-timeout status" "$(status_of "$r")" 504
expect_eq "engine-timeout code" "$(json_get 'd["code"]' <<<"$(body_of "$r")")" timeout
(( elapsed < 2500 )) || fail "engine-timeout took ${elapsed}ms"
kill -TERM "$to_pid"; wait "$to_pid" 2>/dev/null || true
unset MACLANG_MOCK_DELAY_MS

# I-SRV-10: another program holds the port -> exit 1
holder_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
python3 -I "$holder_dir/port-holder.py" $port "$work/holder.err" &
py_pid=$!; pids+=("$py_pid")
for _ in $(seq 1 350); do listening && break; sleep 0.1; done   # the helper retries the bind for up to 30 s
listening || { cat "$work/holder.err" 2>/dev/null >&2; fail "I-SRV-10 could not occupy the port"; }
set +e; MACLANG_ENGINE=mock "$bin" serve --port $port 2>"$work/occupied.log"; rc=$?; set -e
expect_eq "I-SRV-10 exit" "$rc" 1
kill "$py_pid" 2>/dev/null || true; wait "$py_pid" 2>/dev/null || true
for _ in $(seq 1 30); do listening || break; sleep 0.1; done

# I-SRV-11: real engine outside a GUI session is refused before binding
if [[ "$(/bin/launchctl managername 2>/dev/null || echo unknown)" != "Aqua" ]]; then
  set +e; env -u MACLANG_ENGINE "$bin" serve --port $port 2>"$work/refuse.log"; rc=$?; set -e
  expect_eq "I-SRV-11 exit" "$rc" 75
  grep -q session_unavailable "$work/refuse.log" || fail "I-SRV-11 stderr"
  listening && fail "I-SRV-11 bound the port"
else
  echo "note: I-SRV-11 skipped (running inside an Aqua session)"
fi

# Invalid flags fail fast
set +e; MACLANG_ENGINE=mock "$bin" serve --port abc 2>/dev/null; rc=$?; set -e
expect_eq "bad --port exit" "$rc" 64

listening && fail "port still bound at the end"
echo "ok: serve contract"
