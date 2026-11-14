#!/usr/bin/env bash
# CLI contract test. Usage: cli-contract.sh <maclang-binary>
# Everything runs against the mock engine (MACLANG_ENGINE=mock) except the doctor check,
# which must work without it. The real Translation framework is never called here.
set -euo pipefail

bin=${1:?usage: cli-contract.sh <binary>}
export MACLANG_HOME
MACLANG_HOME=$(mktemp -d)
trap 'rm -rf "$MACLANG_HOME"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
now_ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time()*1000'; }
expect_eq() { [[ "$2" == "$3" ]] || fail "$1: expected [$3], got [$2]"; }
mock() { MACLANG_ENGINE=mock "$@"; }

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

# I-CLI-2: stdin (one trailing newline stripped)
expect_eq "I-CLI-2 stdin" "$(printf 'hello\n' | mock "$bin" translate --from en --to ko)" "[mock en→ko] hello"
expect_eq "I-CLI-2 stdin multi-line" "$(printf 'a\nb\n' | mock "$bin" translate --from en --to ko --format json)" '{"translatedText":"[mock en→ko] a\nb"}'

# I-CLI-3: empty input -> 64
for input in "" "   " $'\n'; do
  set +e; printf '%s' "$input" | mock "$bin" translate --from en --to ko >/dev/null 2>&1; rc=$?; set -e
  expect_eq "I-CLI-3 empty stdin [$input]" "$rc" "64"
done
set +e; mock "$bin" translate "  " --from en --to ko >/dev/null 2>&1; rc=$?; set -e
expect_eq "I-CLI-3 blank arg" "$rc" "64"
set +e; mock "$bin" translate "x" --from en >/dev/null 2>&1; rc=$?; set -e
expect_eq "I-CLI-3 missing --to" "$rc" "64"
set +e; "$bin" bogus >/dev/null 2>&1; rc=$?; set -e
expect_eq "unknown command" "$rc" "64"

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

echo "ok: cli contract"
