LISP ?= sbcl
SBCL_FLAGS ?= --no-userinit --non-interactive --disable-debugger

export LISP

.PHONY: all test build smoke verify deps clean version

all: test build

# Zero external dependencies: only SBCL + ASDF/UIOP (ships with SBCL).
# scripts/test.sh registers lisp/bridge-gate.asd, forces a fresh compile
# (cached fasls can hide a new warning) and treats compiler warnings in this
# project's own code as errors.
test:
	./scripts/test.sh

build:
	$(LISP) --no-userinit --script lisp/build.lisp

smoke: build
	./scripts/verify.sh

verify: test smoke

# Fail if the system resolves to anything other than in-repo systems; asks
# ASDF rather than pattern-matching the .asd text.
deps:
	./scripts/deps.sh

version:
	@cat VERSION

clean:
	rm -rf bin .bridge .ci-smoke
