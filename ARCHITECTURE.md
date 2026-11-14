# bridge-gate - Architecture

`bridge-gate` is a single SBCL executable. The CLI dispatches to three commands;
all policy evaluation is pure and all network access goes through one injectable
client shape so tests can run offline.

## Goals

1. Use one runtime: SBCL.
2. Keep policy evaluation pure, deterministic, and easy to audit.
3. Keep the gate fail-closed: unknown input never yields a pass.
4. Keep the build free of external Lisp libraries.

## Runtime

- Compiler and runtime: SBCL 2.4 or newer.
- Build and system definition: ASDF (`lisp/bridge-gate.asd`).
- External Lisp libraries: none. `:depends-on ()` for both systems.
- Quicklisp: not used.
- Build output: `bin/bridge-gate` (git-ignored).

The source is Common Lisp. The repository has one implementation.

## Repository layout

```
lisp/
├── bridge-gate.asd     system + test system definitions
├── build.lisp          image dump -> ../bin/bridge-gate
├── src/                library sources
└── test/               offline test suite
scripts/
├── test.sh             fail-closed test gate
├── verify.sh           binary smoke test (exit codes 0/1/2)
└── deps.sh             asserts no external ASDF dependencies
```

## Component map

```
CI/CD Pipeline ──invoke──▶ bridge-gate CLI (lisp/src/core.lisp)
                              │ auth                    │ gates (exit code)
                              ▼                         ▼
                      lisp/src/cyberark.lisp ──creds──▶ CyberArk Vault (CCP/Conjur)
                              │ inject (credential)
                              ▼
                      lisp/src/tenable.lisp ──launch/poll/export──▶ Tenable (io / sc)
                              │ write findings.json
                              ▼
                      .bridge artifacts ──eval──▶ lisp/src/policy.lisp (pure EDN eval)
                                                       │ exit 0 PASS ──▶ CLI ──▶ CI deploys
                                                       │ BLOCK ──▶ ServiceNow + Slack payload
```

## Modules

| File | Responsibility |
|---|---|
| `lisp/src/core.lisp` | Command parsing, dispatch, exit codes, findings input, report writing |
| `lisp/src/config.lisp` | Defaults < `config.edn` < environment < CLI merge |
| `lisp/src/cyberark.lisp` | CCP and Conjur credential flows with an injectable HTTP client |
| `lisp/src/tenable.lisp` | Tenable.io / Tenable.sc launch, poll, export, and normalization |
| `lisp/src/policy.lisp` | Pure evaluation over normalized findings; ServiceNow/Slack payload |
| `lisp/src/edn.lisp` | Minimal EDN reader for config and policy files |
| `lisp/src/json.lisp` | JSON parsing plus a deterministic, sorted-key emitter |
| `lisp/src/http.lisp` | curl-subprocess client returning status/body/headers maps |
| `lisp/src/util.lisp` | Strings, maps, severity coercion, EDN-style `pr-str` |
| `lisp/src/conditions.lisp` | `app-error` carrying a message and detail plist |

## Trust and failure model

- Credentials are fetched per invocation and never logged. The mock mode returns
  a fixed synthetic credential without touching the network.
- Vendor severities are coerced fail-closed: unknown values become `:critical`.
- Policy evaluation never performs I/O; a missing or unreadable policy file is an
  execution error (exit 2), while a policy violation is a gate decision (exit 1).
- A violation writes the block payload before exiting, so CI always has an
  artifact to attach to a ticket or chat notification.
- HTTP error statuses are returned to the connector rather than signaled by the
  client; connectors turn non-2xx responses into application errors (exit 2).
- The standalone image is saved with `:save-runtime-options t`; application
  flags such as `--help` are passed to the entry point instead of being
  consumed by the SBCL runtime.
- `lisp/build.lisp` resolves `:toplevel` with `find-symbol` after the system
  loads (a literal symbol would be read before its package exists) and strips
  relative `XDG_DATA_DIRS` entries, which ASDF's default source registry
  rejects in sandboxed or mounted environments.

## Data contracts

- Credential: `(:username :secret :expiry)`.
- Scan: `(:scan-id :target :status :findings [(:host :plugin-id :name :severity :port)])`.
- Gate result: `(:passed? :violations :summary)`.
- Block payload: `:event`, `:tool`, `:timestamp`, `:target`, `:scan-id`,
  `:policy`, `:passed?`, `:summary`, `:violations`, `:servicenow`, `:slack`.

Booleans are represented explicitly in memory (`t` / `:false`) and emitted as
JSON `true` / `false`; `nil` is JSON `null`, and an empty vector is `[]`.

## Build and test

```bash
make test     # scripts/test.sh: forced compile, warnings are errors
make build    # sbcl --no-userinit --script lisp/build.lisp
make smoke    # build + scripts/verify.sh
make verify   # test + smoke (what CI runs)
make deps     # asserts no external ASDF dependencies
```

Exit codes are a contract: `0` gate passed, `1` policy violation (block JSON
written), `2` usage or execution error. `scripts/verify.sh` asserts each one
against the real binary.
