# markfluence-action
#
# `make check` is what CI runs, and CI runs nothing else, so what gets checked
# here and what gets checked on a runner cannot drift.
#
# The tool *versions* still can, in one direction only. CI pins and
# checksum-verifies all three (see .github/workflows/ci.yml), so its answer is
# reproducible; these rules use whatever is on your PATH, so yours may not
# match. That has already bitten once: an "A && B || C" in install.sh was
# clean under a local shellcheck 0.11.0 and failed CI under the ubuntu image's
# 0.9.0 with SC2015 -- which is why CI no longer takes shellcheck from the
# image at all.
#
# So a clean run here is good evidence, not a guarantee. CI's versions are in
# that workflow if you want to match them exactly.
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

# The test harness is linted too, not just the installer: it is the larger of
# the two scripts and does process substitution and argument building, so a
# quoting regression there would ship with no signal at all.
.PHONY: shellcheck
shellcheck:  ## Lint the shell scripts
	shellcheck --version
	shellcheck setup/install.sh publish/publish.sh tests/*.sh

# actionlint covers .github/workflows ONLY -- it reports "Collected 1 YAML
# files" here and does not read setup/action.yml. So the `run:` block that
# actually ships to consumers is checked by zizmor alone, and shell added to an
# action.yml would be checked by nothing. Do not read this target as covering
# the actions themselves.
.PHONY: actionlint
actionlint:  ## Lint .github/workflows (not setup/action.yml -- see the comment)
	actionlint --version
	actionlint

# No flag needed to get the online audits -- the ones that catch a
# known-vulnerable or stale third-party action. zizmor runs them whenever it
# finds a GitHub token in the environment and falls back to the offline subset
# when it does not, printing a WARN saying so. CI sets GH_TOKEN and therefore
# gets the full set; a local run gets the subset unless you export one.
#
# So this is the one place `make check` is knowingly not identical in the two
# environments. The alternatives were demanding a token to lint, or never
# running the audits that matter most as `uses:` entries accumulate.
#
# (There is no --online-audits flag. The only switch is --no-online-audits,
# which turns them off; asking for them explicitly fails with "unexpected
# argument".)
.PHONY: zizmor
zizmor:  ## Audit the workflows and action definitions for security problems
	zizmor --version
	zizmor .

.PHONY: test
test: test-install test-publish  ## Run both test suites

# Needs network: it downloads real markfluence releases. Deliberate -- the
# thing under test is a downloader, and stubbing the download would only prove
# the stub works.
.PHONY: test-install
test-install:  ## Exercise setup/install.sh against real releases (needs network)
	./tests/install_test.sh

# No network and no credentials: a throwaway git repository and a fake
# markfluence on PATH. What is under test is which files get selected and what
# gets reported, not the publishing itself.
.PHONY: test-publish
test-publish:  ## Exercise publish/publish.sh with a stubbed markfluence
	./tests/publish_test.sh
