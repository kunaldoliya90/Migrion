# Thin wrappers around scripts/db.sh - without make, run
# `bash scripts/db.sh <command> [args]` instead; it's the same thing.
NAME :=
CHANGE :=
BASE :=
SCRIPT := bash scripts/db.sh

.PHONY: db-doctor db-branch db-check db-new db-migration db-sync db-migrate db-migrate-prod db-status db-verify

db-doctor:
	@$(SCRIPT) doctor

db-branch:
	@$(SCRIPT) branch $(NAME) $(CHANGE)

db-check:
	@$(SCRIPT) check

db-new:
	@$(SCRIPT) new $(NAME)

db-migration:
	@$(SCRIPT) migration

db-sync:
	@$(SCRIPT) sync

db-migrate:
	@$(SCRIPT) migrate

db-migrate-prod:
	@$(SCRIPT) migrate-prod

db-status:
	@$(SCRIPT) status

db-verify:
	@$(SCRIPT) verify $(BASE)
