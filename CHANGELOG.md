# Changelog

## v0.2.1 — 2026-11-14

Zero-dependency completion and build hardening for the SBCL port.

- `lisp/build.lisp` resolves its entry point at runtime (`find-symbol`), so
  `sbcl --no-userinit --script lisp/build.lisp` no longer trips over a reader error
  before `bridge-gate.core` exists.
- `lisp/build.lisp` and `scripts/test.sh` sanitize `XDG_DATA_DIRS`, dropping
  relative entries such as `./share/` that sandbox / mount environments inject
  and that ASDF's default source registry rejects. Test and build gates now
  give the same result on a workstation, in CI, and inside a mounted app.
- Entry point uses `uiop:command-line-arguments` / `uiop:quit`; the saved image
  still passes `--help` and every CLI flag through to the application.
- `make test` runs `scripts/test.sh` (forced fresh compile, warnings as
  errors); `make verify` chains test → build → smoke.
- Confirmed `:depends-on ()` for both `bridge-gate` and `bridge-gate/tests`;
  no external or third-party Lisp libraries anywhere.
- Suite unchanged at 41 tests / 147 assertions.

## v0.2.0 — 2026-11-14

Port to Common Lisp / SBCL.

- Same three-command CLI (`cyberark-auth`, `tenable-scan --target`, `enforce-gate`)
  with exit codes 0 PASS / 1 BLOCK + `block.json` / 2 error.
- Zero ASDF/Quicklisp dependencies (`:depends-on ()`): in-tree EDN reader,
  JSON parser, deterministic sorted-key emitter, and a curl-subprocess HTTP
  transport for live calls. Tests inject mock clients and run fully offline.
- Swappable connectors: CyberArk CCP + Conjur; Tenable.io + Tenable.sc, with an
  injectable HTTP client.
- Pure Common Lisp EDN policy engine (`policies/mas_trm.edn`); `.rego` kept as
  reference only.
- ServiceNow + Slack block-payload generation with optional `--notify-webhook`.
- Offline `--mock` / `BRIDGE_MOCK=true` mode across all commands.
- Deterministic JSON output: sorted keys, explicit booleans (`true` / `false` /
  `null`), and `[]` for empty arrays.
- Standalone `bin/bridge-gate` built with `sb-ext:save-lisp-and-die`
  (`:executable t :compression t :save-runtime-options t`); the saved image
  passes `--help` and all CLI flags to the application instead of SBCL's
  runtime.
- Entry point uses `uiop:command-line-arguments` / `uiop:quit`.
- Self-contained suite: 41 tests / 147 assertions, zero network, compiler warnings treated
  as errors.
- Docs written for SBCL.

## v0.1.0 — 2026-09-06

Initial public release.

- Three-command CLI: `cyberark-auth`, `tenable-scan --target`, `enforce-gate`.
- Swappable CyberArk and Tenable connectors.
- EDN policy engine and ServiceNow/Slack block payloads.
- Offline mock mode and a 21-test / 80-assertion suite.
