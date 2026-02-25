COMPOSE := docker compose
BRANCH  ?= develop

GITHUB_ORG := 100-hours-a-week
FE_REPO    := https://github.com/$(GITHUB_ORG)/5-team-service-fe.git
BE_REPO    := https://github.com/$(GITHUB_ORG)/5-team-service-be.git
AI_REPO    := https://github.com/$(GITHUB_ORG)/5-team-service-ai.git

.PHONY: help setup pull pull-fe pull-be pull-ai sync up down restart build \
        logs logs-be logs-fe logs-ai logs-chat \
        logs-nginx logs-mysql logs-redis ps clean redis-cli mysql-cli deps

help: ## Show available commands
	@echo ""
	@echo "Usage: make <command>"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'
	@echo ""

# ─── Setup & Sync ────────────────────────────────────────────

setup: ## Clone all repos and prepare .env
	@[ -d Frontend/.git ] || git clone -b $(BRANCH) $(FE_REPO) Frontend
	@[ -d Backend/.git ]  || git clone -b $(BRANCH) $(BE_REPO) Backend
	@[ -d AI/.git ]       || git clone -b $(BRANCH) $(AI_REPO) AI
	@[ -f .env ] || cp .env.example .env
	@echo "Setup complete. Edit .env if needed, then run: make up"

## Helper: pull a single repo safely
## Usage: $(call safe_pull,<dir>)
## - If on develop → fetch + pull
## - If on another branch → skip with warning
define safe_pull
	@CURRENT=$$(git -C $(1) rev-parse --abbrev-ref HEAD 2>/dev/null); \
	if [ "$$CURRENT" = "$(BRANCH)" ]; then \
		echo "  $(1): pulling $(BRANCH)..."; \
		git -C $(1) pull origin $(BRANCH); \
	else \
		echo "  $(1): on '$$CURRENT' (not $(BRANCH)) → skipped"; \
	fi
endef

## Helper: pull current branch of a repo regardless of branch name
define force_pull
	@CURRENT=$$(git -C $(1) rev-parse --abbrev-ref HEAD 2>/dev/null); \
	echo "  $(1): pulling $$CURRENT..."; \
	git -C $(1) pull origin $$CURRENT
endef

pull: ## Pull develop (skip repos on other branches), rebuild
	@echo "==> Pulling $(BRANCH) for repos on $(BRANCH)..."
	$(call safe_pull,Frontend)
	$(call safe_pull,Backend)
	$(call safe_pull,AI)
	@echo "==> Rebuilding and restarting..."
	$(COMPOSE) up --build -d
	@echo "Done. Run 'make ps' to check status."

pull-fe: ## Pull current branch for Frontend only
	$(call force_pull,Frontend)

pull-be: ## Pull current branch for Backend only
	$(call force_pull,Backend)

pull-ai: ## Pull current branch for AI only
	$(call force_pull,AI)

sync: ## Pull current branch for ALL repos (regardless of branch), rebuild
	@echo "==> Syncing all repos (current branch)..."
	$(call force_pull,Frontend)
	$(call force_pull,Backend)
	$(call force_pull,AI)
	@echo "==> Rebuilding and restarting..."
	$(COMPOSE) up --build -d
	@echo "Done. Run 'make ps' to check status."

# ─── Compose Lifecycle ───────────────────────────────────────

up: ## Build and start all services
	$(COMPOSE) up --build -d
	@echo "All services starting. Run 'make ps' or 'make logs' to monitor."

down: ## Stop all services
	$(COMPOSE) down

restart: ## Restart all services
	$(COMPOSE) restart

build: ## Rebuild all images (no restart)
	$(COMPOSE) build

clean: ## Stop and remove everything including volumes
	$(COMPOSE) down -v
	@echo "All containers and volumes removed."

# ─── Logs ────────────────────────────────────────────────────

logs: ## Follow all service logs
	$(COMPOSE) logs -f

logs-be: ## Follow backend logs
	$(COMPOSE) logs -f backend

logs-fe: ## Follow frontend logs
	$(COMPOSE) logs -f frontend

logs-chat: ## Follow chat logs
	$(COMPOSE) logs -f chat

logs-ai: ## Follow AI logs
	$(COMPOSE) logs -f ai

logs-nginx: ## Follow nginx logs
	$(COMPOSE) logs -f nginx

logs-mysql: ## Follow MySQL logs
	$(COMPOSE) logs -f mysql

logs-redis: ## Follow Redis logs
	$(COMPOSE) logs -f redis

# ─── CLI Access ──────────────────────────────────────────────

redis-cli: ## Open Redis CLI
	$(COMPOSE) exec redis redis-cli

mysql-cli: ## Open MySQL CLI (doktoridb)
	$(COMPOSE) exec mysql sh -c 'mysql -u root -p$$MYSQL_ROOT_PASSWORD doktoridb'

# ─── Status ──────────────────────────────────────────────────

ps: ## Show service status
	$(COMPOSE) ps

# ─── Local IDE Development ───────────────────────────────────

deps: ## Start only MySQL + Redis (for local IDE development)
	$(COMPOSE) up -d mysql redis
	@echo ""
	@echo "  MySQL : localhost:3307"
	@echo "  Redis : localhost:6379"
	@echo ""
	@echo "Run your service locally in IDE."
