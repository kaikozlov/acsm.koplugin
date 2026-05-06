# Makefile for acsm.koplugin
#
# Uses the koplugin-dev Docker image from GHCR for a unified test environment.
# No local toolchain required — just Docker.
#
# Quick start:
#   make setup     # pull the image (one-time)
#   make test      # run all tests
#   make test-e2e  # run e2e tests (hits real Adobe servers)
#   make shell     # drop into the container

PLUGIN_NAME := acsm
KOPLUGIN_DEV_VERSION := v2026.03_2
IMAGE := ghcr.io/kaikozlov/koplugin-dev:$(KOPLUGIN_DEV_VERSION)

# SDL dummy driver for headless KOReader
SDL_ENV := -e SDL_VIDEODRIVER=dummy

# Mount current repo as /opt/plugin
MOUNT := -v "$(PWD)":/opt/plugin -e PLUGIN_NAME=$(PLUGIN_NAME)

# Standard run (no network)
RUN := docker run --rm $(SDL_ENV) $(MOUNT) $(IMAGE)
# Network-enabled run (for e2e tests that hit real servers)
RUN_NETWORK := docker run --rm --network=host $(SDL_ENV) $(MOUNT) $(IMAGE)
# Interactive run
RUN_IT := docker run --rm -it $(SDL_ENV) $(MOUNT) $(IMAGE)

# =============================================================================
# Setup
# =============================================================================

.PHONY: setup
setup: ## Pull the koplugin-dev image
	docker pull $(IMAGE)

# =============================================================================
# Testing
# =============================================================================

.PHONY: test
test: ## Run all tests (excludes e2e)
	$(RUN) busted-koreader --verbose \
		--helper=/opt/koplugin-dev/commonrequire.lua \
		--exclude-tags=e2e \
		/opt/plugin/spec/

.PHONY: test-e2e
test-e2e: ## Run E2E tests only (requires network — hits real Adobe servers)
	$(RUN_NETWORK) busted-koreader --verbose \
		--helper=/opt/koplugin-dev/commonrequire.lua \
		--filter=e2e \
		/opt/plugin/spec/

.PHONY: test-all
test-all: ## Run all tests including e2e (requires network)
	$(RUN_NETWORK) busted-koreader --verbose \
		--helper=/opt/koplugin-dev/commonrequire.lua \
		/opt/plugin/spec/

.PHONY: test-filter
test-filter: ## Run tests matching FILTER pattern (pass FILTER="...")
	$(RUN) busted-koreader --verbose \
		--helper=/opt/koplugin-dev/commonrequire.lua \
		--filter="$(FILTER)" \
		/opt/plugin/spec/

# =============================================================================
# Linting
# =============================================================================

.PHONY: lint
lint: ## Run luacheck inside the container
	$(RUN) luacheck /opt/plugin

# =============================================================================
# Interactive
# =============================================================================

.PHONY: shell
shell: ## Drop into a shell in the dev container
	$(RUN_IT) /bin/bash

.PHONY: lua
lua: ## Start KOReader's LuaJIT REPL
	$(RUN_IT) /opt/lib/koreader/luajit

# =============================================================================
# Cleanup
# =============================================================================

.PHONY: clean
clean: ## Remove test artifacts
	rm -f test-results.xml

.PHONY: help
help: ## Show this help
	@echo "$(PLUGIN_NAME).koplugin targets:"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'
