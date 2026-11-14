#!/usr/bin/env bash
# Dependency guard: bridge-gate must resolve to in-repo systems only.
#
# Asks ASDF for each system's declared dependencies instead of pattern
# matching the .asd text, so `("bridge-gate")` on bridge-gate/tests passes
# while any external (Quicklisp or otherwise) system fails the gate.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LISP="${LISP:-sbcl}"

if [[ -n "${XDG_DATA_DIRS:-}" ]]; then
  sanitized=""
  IFS=':' read -r -a entries <<< "$XDG_DATA_DIRS"
  for entry in "${entries[@]}"; do
    [[ "$entry" == /* ]] || continue
    sanitized="${sanitized:+$sanitized:}$entry"
  done
  export XDG_DATA_DIRS="${sanitized:-/usr/local/share:/usr/share}"
fi

cd "$ROOT"

exec "$LISP" --no-userinit --non-interactive --disable-debugger \
  --eval '(require :asdf)' \
  --eval '(asdf:load-asd (merge-pathnames "lisp/bridge-gate.asd" (uiop:getcwd)))' \
  --eval '(dolist (name (list "bridge-gate" "bridge-gate/tests")) 
            (dolist (dependency (asdf:system-depends-on (asdf:find-system name)))
              (unless (string= dependency "bridge-gate")
                (error "~a declares external system dependency ~a" name dependency))))' \
  --eval '(format t "OK: bridge-gate has no external ASDF dependencies~%")'
