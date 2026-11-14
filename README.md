# maclang

On-device translation and language detection for macOS, as a single Swift command-line tool.

- Translates with Apple's Translation framework. Text never leaves the Mac.
- Detects languages with NaturalLanguage, in any session.
- Serves a LibreTranslate-compatible HTTP API on localhost for other tools and scripts.

No third-party dependencies. Requires macOS 26 or later on Apple silicon.

## Install

```sh
mise use -g github:junmo-kim/mac-local-language
```

or download the `maclang-<tag>-macos-arm64.tar.gz` asset from a release, verify its `.sha256`, and put `maclang` on your `PATH`.

## Usage

```sh
maclang translate "The quick brown fox" --to ko
echo "Bonjour tout le monde" | maclang translate --to en --format json
maclang detect "Bonjour tout le monde"          # fr
maclang languages --from en --format json
maclang doctor
```

Common options: `--from LANG|auto` (default `auto`), `--to LANG`, `--strategy high-fidelity|low-latency` (without `--strategy`, maclang always requests high fidelity), `--format text|json|yaml`, `--timeout SEC` (default 60; must be above 0 and at most 86400), `--route auto|local|server`. TEXT is read from stdin when omitted. Language codes are the minimal BCP 47 form (`zh` is Simplified, `zh-TW` is Traditional, `pt-PT`, `en`); `zt` is accepted as an alias for Traditional Chinese.

Data goes to stdout and errors to stderr as `error: <message> (<code>)`.

## Why a server?

Apple's Translation framework only works from a process that runs inside a graphical (Aqua) login session. From SSH, a CI agent or another non-GUI context, a direct call never returns. So `maclang` decides per call:

| `--route` | engine | session | result |
|---|---|---|---|
| `local` | any | any | run in this process |
| `server` | any | any | forward to the server |
| `auto` | mock | any | local |
| `auto` | Apple | GUI | local |
| `auto` | Apple | not GUI | forward to the server |

When forwarding, the CLI checks `GET /health` on the configured host and port. If nothing answers it builds a small signed app bundle (`MacLang.app`) in its home directory and starts it with `open`, which places the server inside your GUI session, then waits for it to become healthy (set `MACLANG_AUTOSTART=0` to disable). `detect` is always local.

## HTTP API

`maclang serve [--host H] [--port N] [--max-body-kib K] [--engine-timeout SEC]` listens on `127.0.0.1:9091` by default (see `config.json` below). The real engine refuses to start outside a GUI session (exit 75).

| Request | Notes |
|---|---|
| `GET /health` | `{"status":"ok","version":…,"pid":…,"session":…,"engine":…,"label":…,"executable":…}` |
| `POST /translate` | JSON or form body: `q` (string or array of up to 100), `source` (`auto` allowed), `target`, optional `format` (`text`), `alternatives`, `api_key` (ignored), and the extension `strategy` (`high-fidelity` or `low-latency`). Answers `{"translatedText":…}` plus `detectedLanguage` when `source` is `auto`; text whose language cannot be detected is translated as English and reported with confidence 0 (as LibreTranslate does). |
| `POST /detect` | `q` (string). Answers up to three `{"confidence":0-100,"language":…}` entries, or `unable_to_detect` when nothing can be detected. |
| `GET /languages` | Optional `?strategy=`. Answers `[{"code","name","targets"}]`, targets limited to installed language packs. |

The API accepts JSON and `application/x-www-form-urlencoded` bodies with a `Content-Length` (no multipart, no chunked uploads), sends no CORS headers, and is meant for local clients; it has no authentication, so keep it bound to loopback unless you know what you are doing.

Errors are `{"error":"…","code":"…","fix":"…"}`, plus `"field"` and `"received"` (an echo of the offending input) when they apply, always in that key order. `error` is the human message (kept for LibreTranslate compatibility), `fix` is the next action to take. The CLI prints `error: <message> (<code>)` on stderr, followed by `fix:` (and `field:` / `received:`) lines; when it forwarded the request, those come from the server's answer. The table lists each code's default fix; many errors carry a more specific one.

| code | HTTP | CLI exit | Fix (default) |
|---|---|---|---|
| `invalid_request` | 400 | 64 | see `maclang <command> --help`; HTTP API: `POST /translate {"q":"Hello","source":"auto","target":"ko"}` |
| `unsupported_language` | 400 | 69 | list installed pairs with `maclang languages --from <source>` (HTTP: `GET /languages`) and use one of the listed codes |
| `not_installed` | 400 | 69 | install the pair in System Settings > General > Language & Region > Translation Languages, or omit `--strategy` (maclang then requests high fidelity) |
| `unable_to_detect` | 400 | 65 (`detect` only) | pass the language explicitly (`--from <code>`; HTTP: `"source"`) |
| `payload_too_large` | 413 | 64 | split the text into smaller requests, or start the server with a larger `serve --max-body-kib` |
| `not_found` | 404 | 64 | use `GET /health`, `POST /translate`, `POST /detect` or `GET /languages` |
| `method_not_allowed` | 405 | 64 | use the method listed for this path |
| `timeout` | 504 | 75 | retry; for long texts raise `--timeout` (CLI) or `serve --engine-timeout`; check `maclang service status` |
| `session_unavailable` | CLI only | 75 | log in to this Mac's desktop (a locked screen is fine), then retry; check `maclang doctor` and the server log |
| `invalid_config` | CLI only | 78 | fix or delete `config.json` in the maclang home (example: `{"host":"127.0.0.1","port":9091}`) or rerun `maclang service install --port <N>` |
| `internal` | 500 | 1 | retry; if it persists, check the server log and `maclang doctor` |

`--format json` on the CLI prints exactly the body the HTTP API returns. Server logs never contain request text or translations.

## Run it as a service

```sh
maclang service install --port 9091   # writes config.json and a LaunchAgent, then loads it
maclang service status
maclang service stop | start
maclang service uninstall
```

State lives in `~/Library/Application Support/maclang` (`config.json`, `MacLang.app`, `logs/server.log`). `MACLANG_HOME`, `MACLANG_LABEL` and `MACLANG_LAUNCH_AGENTS_DIR` relocate it, which is useful for testing.

## Limitations

- The server only runs while a user is logged in to a graphical session. Nothing translates before login, and with FileVault the login screen comes first.
- Language packs are installed in System Settings > General > Language & Region > Translation Languages. A missing pack is reported as `not_installed`. Without `--strategy`, maclang uses the system's preferred strategy (high fidelity on macOS 27); `low-latency` usually needs its own packs.
- Output quality is that of Apple's on-device models, which tend to be literal.
- `MACLANG_ENGINE=mock` swaps in a fake engine for tests. It is not for real use.

## Development

```sh
swift build -c release -Xlinker -s
swift test
Tests/Integration/cli-contract.sh .build/release/maclang
Tests/Integration/serve-contract.sh .build/release/maclang
```

`Tests/Integration/session-e2e.sh` exercises the real engine and LaunchAgent and needs a graphical login session. It is not run in CI.

Releases: write the release's one-paragraph highlight under `## Unreleased` in `CHANGELOG.md` and rename it to `## vX.Y.Z` before tagging. `scripts/gen-release-notes.sh` puts it at the top of the GitHub release notes, followed by the commit list.

## License

MIT, see [LICENSE](LICENSE).
