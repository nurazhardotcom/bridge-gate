#!/usr/bin/env bash
# Fail-closed, environment-independent test gate.
#
# Registers lisp/bridge-gate.asd directly, loads bridge-gate/tests with a
# forced recompile, and treats every compiler warning in this project's own
# code as an error. Only SBCL + ASDF/UIOP are used: no Quicklisp.
#
# XDG_DATA_DIRS is sanitized first: ASDF builds its default source registry
# from that variable and aborts on relative entries such as "./share/", which
# sandbox / AppImage mount environments inject. Only absolute entries survive.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LISP="${LISP:-sbcl}"

if [[ -n "${XDG_DATA_DIRS:-}" ]]; then
  sanitized=""
  IFS=':' read -r -a entries <<< "$XDG_DATA_DIRS"
  for entry in "${entries[@]}"; do
    [[ "$entry" == /* ]] || continue
    if [[ -n "$sanitized" ]]; then
      sanitized="$sanitized:$entry"
    else
      sanitized="$entry"
    fi
  done
  export XDG_DATA_DIRS="${sanitized:-/usr/local/share:/usr/share}"
fi

cd "$ROOT"

# ASDF must find lisp/bridge-gate.asd; keep the environment clean so a
# developer's global registry cannot substitute a different system.
export CL_SOURCE_REGISTRY="(:source-registry (:tree \"$ROOT/lisp/\") :ignore-inherited-configuration)"

exec "$LISP" --no-userinit --non-interactive --disable-debugger \
  --eval '(require :asdf)' \
  --eval '(asdf:load-asd (merge-pathnames "lisp/bridge-gate.asd" (uiop:getcwd)))' \
  --eval '(setf asdf:*compile-file-warnings-behaviour* :error)' \
  --eval '(asdf:load-system :bridge-gate/tests :force t)' \
  --eval '(asdf:test-system "bridge-gate")'
