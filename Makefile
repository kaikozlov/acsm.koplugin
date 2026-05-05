# Makefile for acsm.koplugin
# All tests run inside Docker with KOReader's real LuaJIT + native libs.
#
# Usage:
#   make test            — run all tests in Docker (excludes e2e/network tests)
#   make test-e2e        — run E2E tests (requires network — hits real Adobe servers)
#   make test-all        — run everything including e2e
#   make test-filter     — run tests matching FILTER pattern (pass FILTER="...")
#   make docker-build    — build the Docker test image
#   make docker-shell    — shell into the Docker test container
#   make lint            — run luacheck locally

KOREADER_VERSION ?= v2026.03
# Auto-detect architecture: arm64 on Apple Silicon, x86_64 everywhere else
DOCKER_ARCH ?= $(shell uname -m | sed 's/arm64/aarch64/' | grep -q aarch64 && echo arm64 || echo x86_64)
IMAGE_NAME ?= acsm-test
PLUGIN_DIR := $(shell pwd)

.PHONY: help test test-e2e test-all test-filter lint docker-build docker-shell clean

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

# ---------------------------------------------------------------------------
# Docker image (cached — only rebuilds when KOReader version changes)
# ---------------------------------------------------------------------------

docker-build: ## Build the Docker test image
	docker build \
		--build-arg KOREADER_VERSION=$(KOREADER_VERSION) \
		--build-arg ARCH=$(DOCKER_ARCH) \
		-t $(IMAGE_NAME) .

# ---------------------------------------------------------------------------
# Tests — all run inside Docker with real KOReader
# ---------------------------------------------------------------------------

test: docker-build ## Run all tests (excludes e2e network tests)
	docker run --rm -v "$(PLUGIN_DIR)":/opt/acsm.koplugin $(IMAGE_NAME) \
		busted-koreader --verbose \
		--helper=/opt/acsm.koplugin/spec/commonrequire.lua \
		--exclude-tags=e2e \
		/opt/acsm.koplugin/spec/

test-e2e: docker-build ## Run E2E tests only (requires network — downloads real ACSM from Adobe)
	docker run --rm -v "$(PLUGIN_DIR)":/opt/acsm.koplugin $(IMAGE_NAME) \
		busted-koreader --verbose \
		--helper=/opt/acsm.koplugin/spec/commonrequire.lua \
		--filter=e2e \
		/opt/acsm.koplugin/spec/

test-all: docker-build ## Run all tests including e2e
	docker run --rm -v "$(PLUGIN_DIR)":/opt/acsm.koplugin $(IMAGE_NAME) \
		busted-koreader --verbose \
		--helper=/opt/acsm.koplugin/spec/commonrequire.lua \
		/opt/acsm.koplugin/spec/

test-filter: docker-build ## Run tests matching FILTER pattern (pass FILTER="...")
	docker run --rm -v "$(PLUGIN_DIR)":/opt/acsm.koplugin $(IMAGE_NAME) \
		busted-koreader --verbose \
		--helper=/opt/acsm.koplugin/spec/commonrequire.lua \
		--filter="$(FILTER)" \
		/opt/acsm.koplugin/spec/

docker-shell: docker-build ## Drop into a shell in the test container
	docker run --rm -it -v "$(PLUGIN_DIR)":/opt/acsm.koplugin $(IMAGE_NAME) /bin/bash

# ---------------------------------------------------------------------------
# Local tools (no Docker needed)
# ---------------------------------------------------------------------------

lint: ## Run luacheck
	luacheck .

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

clean: ## Remove Docker images and test artifacts
	docker rmi $(IMAGE_NAME) 2>/dev/null || true
	rm -f test-results.xml
