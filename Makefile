.PHONY: setup db-branch db-new db-check db-migration db-migrate db-status db-migrate-prod

setup:
	@bash scripts/db.sh setup

db-branch:
	@bash scripts/db.sh branch $(NAME) $(CHANGE)

db-new:
	@bash scripts/db.sh new $(NAME)

db-check:
	@bash scripts/db.sh check

db-migration:
	@bash scripts/db.sh migration

db-migrate:
	@bash scripts/db.sh migrate

db-status:
	@bash scripts/db.sh status

db-migrate-prod:
	@bash scripts/db.sh migrate-prod
