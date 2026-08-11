# DOKANDAR dev-infra — developer entrypoint. Always loads config (.env) + secrets (.env.secrets).
# PROFILE selects the service group: core (default) | search | storage | observability | all
DC      = docker compose --env-file .env --env-file .env.secrets
PROFILE ?= core

.PHONY: help secrets up down ps health verify bootstrap all dev obs-up obs-down logs restart pull purge
help:
	@echo "DOKANDAR dev-infra"
	@echo "  make all                      # ONE-COMMAND: secrets + core+search+storage up + bootstrap + verify"
	@echo "  make dev                      # core+search+storage up (no observability) + bootstrap"
	@echo "  make secrets                  # generate .env.secrets"
	@echo "  make up        [PROFILE=core] # start a profile"
	@echo "  make bootstrap                # create topics / queues / per-context DBs / buckets (idempotent)"
	@echo "  make verify    [PROFILE=...]  # functional readiness checks (exit !=0 on failure)"
	@echo "  make health    [PROFILE=...]  # container health summary"
	@echo "  make obs-up | obs-down        # start/stop the Elastic APM observability stack"
	@echo "  make down      [PROFILE=core] # stop a profile (data kept)"
	@echo "  make logs SVC=postgres        # tail a service"
	@echo "  make purge                    # stop ALL + delete volumes (DESTROYS data)"

secrets:
	@./gen-secrets.sh

up:
	@[ -f .env ] || cp .env.example .env
	@[ -f .env.secrets ] || ./gen-secrets.sh
	$(DC) --profile $(PROFILE) up -d

bootstrap:
	@bash bootstrap/run.sh

verify:
	@bash verify.sh

# Bring the full development substrate up (minus observability), initialise it, and verify it.
dev: secrets
	$(DC) --profile core --profile search --profile storage up -d
	@echo "waiting for health..."; sleep 45
	@bash bootstrap/run.sh
	@bash verify.sh

# Everything, including a one-shot observability check.
all: dev obs-up
	@sleep 50; bash verify.sh

obs-up:
	$(DC) --profile observability up -d

obs-down:
	$(DC) stop apm-server apm-kibana apm-elasticsearch 2>/dev/null || true

down:
	$(DC) --profile $(PROFILE) down

ps:
	$(DC) --profile $(PROFILE) ps

health:
	@$(DC) --profile $(PROFILE) ps --format '{{.Name}}\t{{.State}}\t{{.Status}}'

logs:
	$(DC) logs -f $(SVC)

restart:
	$(DC) --profile $(PROFILE) restart

pull:
	$(DC) --profile $(PROFILE) pull

purge:
	$(DC) --profile all down -v
