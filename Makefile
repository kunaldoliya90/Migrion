# Thin wrappers around scripts/db.sh - without make, run
# `bash scripts/db.sh <command> [args]` instead; it's the same thing.
# ENV picks the environment: local (default), staging, production, ...
ENV := local
NAME :=
CHANGE :=
BASE :=
SCRIPT := bash scripts/db.sh

.PHONY: db-doctor db-branch db-check db-new db-new-env db-migration db-sync db-migrate db-migrate-prod db-status db-verify

db-doctor:
	@$(SCRIPT) doctor $(ENV)

db-branch:
	@$(SCRIPT) branch $(NAME) $(CHANGE)

db-check:
	@$(SCRIPT) check

db-new:
	@$(SCRIPT) new $(NAME)

db-new-env:
	@$(SCRIPT) new-env $(ENV)

db-migration:
	@$(SCRIPT) migration

db-sync:
	@$(SCRIPT) sync

db-migrate:
	@$(SCRIPT) migrate $(ENV)

db-migrate-prod:
	@$(SCRIPT) migrate production

db-status:
	@$(SCRIPT) status $(ENV)

db-verify:
	@$(SCRIPT) verify $(BASE)
