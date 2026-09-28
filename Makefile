# Every database command. Without make, run: bash scripts/db.sh <command>
.PHONY: setup db-branch db-new db-check db-migration db-migrate db-status db-migrate-prod

setup:            ## first run: create .env, enable the git hook, start local Postgres
	@bash scripts/db.sh setup
db-branch:        ## make db-branch NAME=user_auth CHANGE=add-phone
	@bash scripts/db.sh branch $(NAME) $(CHANGE)
db-new:           ## make db-new NAME=billing
	@bash scripts/db.sh new $(NAME)
db-check:         ## check naming and schema conventions
	@bash scripts/db.sh check
db-migration:     ## generate migrations from schema.hcl changes
	@bash scripts/db.sh migration
db-migrate:       ## apply pending migrations to your local databases
	@bash scripts/db.sh migrate
db-status:        ## applied / pending migrations per local database
	@bash scripts/db.sh status
db-migrate-prod:  ## apply pending migrations to production (CD only)
	@bash scripts/db.sh migrate-prod
