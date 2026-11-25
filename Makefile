# Install copies this bundle to <share>/bundles/mail, where an import of a
# mail/ module finds it: a bundle is installed when its files are there.

X ?= x

# The version is derived from git describe, never committed: bundle.xon
# declares what this bundle requires; the installed copy carries what it is.
BUNDLE_VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
SHARE := $(if $(PREFIX),$(PREFIX)/share/x,$(shell $(X) --share-dir))
DEST  := $(SHARE)/bundles/mail

# What a consumer needs: the declaration and lib/.  Not the suite, the
# examples, the tooling or CI.
PAYLOAD := bundle.xon lib

.PHONY: install
install: ## Install into <share>/bundles/mail
	@test -n "$(SHARE)" || { echo "x-lib-mail: cannot find an x tree -- set PREFIX or X" >&2; exit 1; }
	@test -d "$(SHARE)" || { echo "x-lib-mail: no x tree at $(SHARE)" >&2; exit 1; }
	rm -rf "$(DEST)"
	mkdir -p "$(DEST)"
	cp -R $(PAYLOAD) "$(DEST)/"
	printf '%s\n' '$(BUNDLE_VERSION)' > "$(DEST)/version"
	@echo "x-lib-mail: installed to $(DEST)"

.PHONY: uninstall
uninstall: ## Remove it again
	rm -rf "$(DEST)"
	@echo "x-lib-mail: removed $(DEST)"

.PHONY: test
test: ## Run the spec suite (every failure is loud)
	X="$(X)" sh tests/spec-runner.sh

.PHONY: doctest
doctest: ## Run the examples the modules' documentation carries
	BUNDLE=. X="$(X)" sh "$$($(X) --share-dir)/tools/bundle-kit/doctest.sh"

.PHONY: check
check: ## Run the suite against tests/contract/known-failures.txt -- what CI gates on
	X="$(X)" sh tests/spec-gate.sh

.PHONY: help
help: ## Show targets
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z0-9_-]+:.*?## / {printf "  \033[32m%-12s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)
