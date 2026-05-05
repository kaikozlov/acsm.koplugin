# Makefile for acsm.koplugin
# Two-tier test system:
#   1. Unit specs (spec/*_spec.lua) — fast, mocked, runs locally with busted+luajit
#   2. Integration specs (spec/integration/) — real KOReader, runs in Docker
#
# Usage:
#   make test            — run unit tests locally (requires luajit + busted)
#   make docker-test     — run integration tests in Docker (requires Docker)
#   make docker-build    — build the Docker test image
#   make docker-shell    — shell into the Docker test container

KOREADER_VERSION ?= v2026.03
# Options: x86_64 (Intel/AMD), arm64 (Apple Silicon / Graviton)
DOCKER_ARCH ?= x86_64
IMAGE_NAME ?= acsm-test

.PHONY: help test lint docker-build docker-test docker-shell docker-busted clean

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

# ---------------------------------------------------------------------------
# Local tests (fast, mocked — no Docker needed)
# ---------------------------------------------------------------------------

test: ## Run unit specs locally (requires luajit + busted)
	busted --verbose --pattern=_spec spec/

lint: ## Run luacheck
	luacheck .

# ---------------------------------------------------------------------------
# Docker tests (real KOReader environment)
# ---------------------------------------------------------------------------

docker-build: ## Build the Docker test image
	docker build \
		--build-arg KOREADER_VERSION=$(KOREADER_VERSION) \
		--build-arg ARCH=$(DOCKER_ARCH) \
		-t $(IMAGE_NAME) .

docker-test: docker-build ## Run integration tests in Docker
	docker run --rm $(IMAGE_NAME)

docker-shell: docker-build ## Drop into a shell in the test container
	docker run --rm -it $(IMAGE_NAME) /bin/bash

docker-busted: docker-build ## Run busted with custom args (pass ARGS="...")
	docker run --rm $(IMAGE_NAME) busted $(ARGS)

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

clean: ## Remove Docker images and test artifacts
	docker rmi $(IMAGE_NAME) 2>/dev/null || true
	rm -f test-results.xml
