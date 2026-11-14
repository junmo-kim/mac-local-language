#!/usr/bin/env bash
set -euo pipefail

# Contracts that can regress even when a release build compiles and links: basic CLI launch,
# NaturalLanguage detection, the mock-engine translate path, and `doctor` never touching the
# real Translation framework or the user's real maclang home.
#
# Usage: Tests/Integration/release-binary-launch-smoke.sh [path-to-maclang-binary]

binary=${1:-.build/release/maclang}
binary=$(cd "$(dirname "$binary")" && pwd)/$(basename "$binary")
tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/maclang-release-smoke.XXXXXX")
trap 'rm -rf "$tmpdir"' EXIT
export MACLANG_HOME="$tmpdir/home" MACLANG_AUTOSTART=0 MACLANG_LAUNCH_AGENTS_DIR="$tmpdir/agents"

die() { echo "release binary smoke test failed: $*" >&2; exit 1; }

version=$("$binary" --version)
[[ "$version" =~ ^maclang\ [0-9]+\.[0-9]+\.[0-9]+$ ]] || die "unexpected version output: $version"
"$binary" --help >/dev/null

doctor="$tmpdir/doctor.json"
"$binary" doctor --format json >"$doctor" 2>"$tmpdir/doctor.err" || { cat "$tmpdir/doctor.err" >&2; die "doctor exited nonzero"; }
python3 - "$doctor" "${version#maclang }" <<'PY' || die "doctor output failed JSON/contract validation"
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
for key in ("version", "macos", "session", "strategy_api", "engine", "home", "label", "bundle", "agent", "server"):
    if key not in d:
        raise SystemExit(f"doctor is missing {key}")
if d["version"] != sys.argv[2]:
    raise SystemExit("doctor version differs from --version")
PY

[[ "$("$binary" detect "Bonjour tout le monde")" == fr ]] || die "detect did not return fr"
[[ "$(MACLANG_ENGINE=mock "$binary" translate hello --from en --to ko)" == "[mock en→ko] hello" ]] || die "mock translate output"

# The smoke run must not have created anything under the real home.
[[ ! -e "$MACLANG_HOME" ]] || die "doctor/translate created $MACLANG_HOME"
echo "ok: release binary smoke"
