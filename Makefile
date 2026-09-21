# markfluence-action
#
# `make check` is what CI runs, and CI runs nothing else, so what gets checked
# here and what gets checked on a runner cannot drift.
#
# The tool *versions* still can. These rules use whatever is on your PATH.
# CI pins actionlint and zizmor, but takes **shellcheck from the runner
# image**, which ships 0.9.0 -- older than a typical Homebrew install, and it
# does not report the same findings. That has already bitten once: an
# "A && B || C" in install.sh was clean under a local 0.11.0 and failed CI
# under 0.9.0 with SC2015.
#
# So a clean run here is good evidence, not a guarantee.
#
# Tools needed: shellcheck, actionlint, zizmor.

SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

.PHONY: help
help:  ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

.PHONY: check
check: shellcheck actionlint zizmor test  ## Everything CI runs, in CI's order

.PHONY: shellcheck
shellcheck:  ## Lint the shell scripts
	shellcheck --version
	shellcheck setup/install.sh

.PHONY: actionlint
actionlint:  ## Lint the workflows, including the shell inside run: blocks
	actionlint --version
	actionlint

.PHONY: zizmor
zizmor:  ## Audit the workflows and action definitions for security problems
	zizmor .

.PHONY: test
test:  ## Exercise install.sh against real markfluence releases (needs network)
	./tests/install_test.sh
