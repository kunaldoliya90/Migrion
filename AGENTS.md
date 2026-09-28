# AGENTS.md

This repo holds every service's Postgres schema and migrations, managed by
Atlas in Docker. `README.md` explains it in a few minutes.

For any database request - a new database, a schema change, migrations,
status - follow `.vibe-code/database-change.md`. The user only talks; you run
the commands and edit the files.

Rules:

- Never commit on `main`. Start every change with
  `make db-branch NAME=<database> CHANGE=<change>`, and deliver it as a pull
  request.
- Edit only `database/<name>/schema.hcl`. Migrations come from
  `make db-migration`; never write or edit them by hand.
- Fix what `make db-check` reports. Never bypass or edit the check.
- Never install tools. Atlas and Postgres run in Docker.
- Production is migrated only by CD. Never commit `.env` or credentials.
