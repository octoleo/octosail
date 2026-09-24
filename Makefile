# Octosail developer targets. Run `make help` for the list.
PREFIX ?= /usr/local
SHELLCHECK ?= shellcheck
BATS ?= bats
ACTIONLINT ?= actionlint
PYTHON ?= python3

SHELL_SOURCES := src/octosail \
	$(wildcard scripts/*.sh) \
	$(wildcard tests/mocks/bin/*) \
	$(wildcard tests/mocks/remote-bin/*) \
	$(wildcard tests/helpers/*.bash)
WORKFLOWS := $(wildcard .github/workflows/*.yml) $(wildcard docs/examples/*.yml)

.PHONY: help test lint docs-check install

help: ## Show this help
	@printf 'Usage: make <target>\n\n'
	@grep -E '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | awk -F ':.*## ' '{ printf "  %-12s %s\n", $$1, $$2 }'

test: ## Run the bats test suite (no AWS, no network)
	$(BATS) -r tests

lint: ## shellcheck every script, actionlint every workflow, parse action.yml
	$(SHELLCHECK) -x -S style $(SHELL_SOURCES)
	@if command -v $(ACTIONLINT) >/dev/null 2>&1; then \
		echo "actionlint $(WORKFLOWS)"; \
		$(ACTIONLINT) $(WORKFLOWS); \
	else \
		echo "notice: actionlint not found on PATH; skipping workflow lint"; \
	fi
	$(PYTHON) -c 'import sys, yaml; yaml.safe_load(open("action.yml", encoding="utf-8")); print("action.yml: valid YAML")'

docs-check: ## Verify docs, script and action.yml agree
	bash scripts/check-docs.sh

install: ## Install the CLI to $(PREFIX)/bin/octosail
	install -d "$(DESTDIR)$(PREFIX)/bin"
	install -m 0755 src/octosail "$(DESTDIR)$(PREFIX)/bin/octosail"
