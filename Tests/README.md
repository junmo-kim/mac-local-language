# Tests

Test names start with an ID whose prefix says which layer it exercises:

| Prefix | Layer | Where | Runs in CI |
|---|---|---|---|
| `U-` | Pure logic in `LangCore` (wire format, config, routing, property lists, …) | `Tests/LangCoreTests` | yes |
| `E-` | `LangEngine` with the mock engine, NaturalLanguage detection and error mapping | `Tests/LangEngineTests` | yes |
| `I-CLI-` | The release binary's CLI against the mock engine | `Tests/Integration/cli-contract.sh` | yes |
| `I-SRV-` | The HTTP server against the mock engine | `Tests/Integration/serve-contract.sh` | yes |
| `R-` | The real Apple Translation engine through an auto-started server and a LaunchAgent | `Tests/Integration/session-e2e.sh` | no |

Named steps without a numeric ID (for example `install-validation` or `undetected-source`) cover specific lifecycle and protocol edge cases in the same scripts.

## Running

```bash
swift build -c release -Xlinker -s
swift test
Tests/Integration/cli-contract.sh .build/release/maclang
Tests/Integration/serve-contract.sh .build/release/maclang
Tests/Integration/privacy-guard.sh
```

`session-e2e.sh` needs a Mac with a user logged in to a graphical session and the Translation language packs installed. It isolates itself with `MACLANG_HOME`, `MACLANG_LABEL=kim.junmo.maclang.e2e` and `MACLANG_LAUNCH_AGENTS_DIR`, uses port 19091, and removes its LaunchAgent and files when it exits. It never calls the Translation framework from the shell itself, because that blocks outside a GUI login session; all real translation goes through the server.
