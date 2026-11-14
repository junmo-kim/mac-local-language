#!/usr/bin/env bash
# maclang translates on-device. Networking APIs may appear only in the two files that talk to
# the local server: the listener (HTTPServer.swift) and the client (ServerClient.swift).
# The pattern bans a named subset of common Apple and POSIX networking entry points; it does
# not claim to be exhaustive.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

# Plain https string literals (e.g. a URL in usage text) are deliberately not flagged.
pattern='URLSession|URLRequest|NSURLConnection|NWConnection|NWListener|NWPath|NWBrowser|NWEndpoint|NWParameters|import Network([^A-Za-z]|$)|getaddrinfo|CFSocket|CFStream|NSStream|dataTask|downloadTask|SOCK_STREAM|SOCK_DGRAM|contentsOf: *URL([^A-Za-z]|$)|(^|[^A-Za-z0-9_])(Darwin\.)?(socket|connect)\(|/usr/bin/(curl|nc|wget)'

if grep -rInE "$pattern" Sources/ \
    | grep -vE '^Sources/maclang/(HTTPServer|ServerClient)\.swift:'; then
  echo "error: a networking API appears outside HTTPServer.swift / ServerClient.swift" >&2
  exit 1
fi
# `--self-test` proves the pattern fires on each sample and not on a plain https literal.
if [[ "${1:-}" == "--self-test" ]]; then
  for sample in 'let d = try Data(contentsOf: URL(string: "x")!)' 'NSURLConnection.send()' 'let fd = socket(AF_INET, 0, 0)' \
                'connect(fd, a, l)' 'Darwin.connect(fd, a, l)' 'run("/usr/bin/curl", [])' 'run("/usr/bin/nc", [])' 'run("/usr/bin/wget", [])'; do
    grep -qE "$pattern" <<<"$sample" || { echo "self-test: pattern missed: $sample" >&2; exit 1; }
  done
  for sample in 'print("https://github.com/junmo-kim/mac-local-language")' 'let d = try Data(contentsOf: paths.config)' 'reconnect = true'; do
    grep -qE "$pattern" <<<"$sample" && { echo "self-test: false positive: $sample" >&2; exit 1; }
  done
  echo "ok: privacy-guard self-test"
  exit 0
fi

echo "ok: no networking APIs outside HTTPServer.swift and ServerClient.swift"
