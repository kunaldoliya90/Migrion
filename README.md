# Migrion

Centralized database schemas and migrations for microservices. One repo holds
every service's Postgres schema and migration history, managed by
[Atlas](https://atlasgo.io). Your services can be written in any language;
none of them owns migrations.

You need **git** and **Docker**. Atlas and Postgres run in containers.

## Quick start

```bash
make setup                                    # .env, git hook, local Postgres
make db-branch NAME=billing CHANGE=create     # never work on main
make db-new NAME=billing                      # database/billing/
# describe your tables in database/billing/schema.hcl
make db-migration                             # generate the migration
make db-migrate                               # apply it locally
git add -A && git commit -m "db(billing): create" && git push -u origin HEAD
# open a pull request; CI checks it, and merging lets CD migrate production
```

No `make` (for example on Windows)? Each target is `bash scripts/db.sh
<command>`, run from Git Bash: `bash scripts/db.sh migrate`.

Working with an AI coding agent? Just ask it, e.g. *"add a billing database"*.
It follows `AGENTS.md`.

## What's where

```
database/<name>/schema.hcl    what the database should look like - edit this
database/<name>/migrations/   generated SQL history + atlas.sum - never edit
atlas.hcl                     one Atlas environment used for every database
docker-compose.yml            postgres (local), atlas (CLI), atlas-dev (scratch)
Makefile, scripts/db.sh       the commands
scripts/check.sh              the conventions check
.githooks/pre-commit          blocks commits on main
.github/workflows/ci.yml      checks every pull request
.github/workflows/cd.yml      migrates production when main changes
```

A database is just a folder under `database/`. Its connection string is the
variable `<NAME>_DATABASE_URL`.

## Commands

| Command | Does |
|---|---|
| `make setup` | Creates `.env`, enables the git hook, starts the local Postgres. |
| `make db-branch NAME=x CHANGE=y` | Updates `main` and creates the branch `db/x/y`. |
| `make db-new NAME=x` | Creates `database/x/` and adds `X_DATABASE_URL` to `.env.example` and `.env`. |
| `make db-check` | Checks the conventions below. |
| `make db-migration` | Generates migrations for changed `schema.hcl` files, and warns about destructive ones. |
| `make db-migrate` | Applies pending migrations to your local databases. |
| `make db-status` | Shows applied and pending migrations locally. |
| `make db-migrate-prod` | Applies pending migrations to production. Runs in CD only. |

## Local and production

| | Connection strings | Migrated by |
|---|---|---|
| **local** | `.env` (created from `.env.example`, never committed) | you: `make db-migrate` |
| **production** | secrets on the GitHub Environment `production` | CD, when a change reaches `main` |

Locally, the URLs point at host `postgres`, the Postgres container. Your own
apps reach the same databases at `localhost:5432`. If port 5432 is already
taken, set `POSTGRES_PORT` in `.env`.

## CI and CD

- **CI** (`ci.yml`) runs on every pull request. It checks:
  - the conventions;
  - that no committed migration was edited;
  - that every `schema.hcl` change has its migration;
  - that destructive migrations carry the label `allow-destructive-migration`.
- **CD** (`cd.yml`) runs when `database/` changes on `main`, and applies
  pending migrations to production. You can also re-run it from the Actions
  tab.

Set up once in GitHub:

1. Create the Environment `production` and add one `<NAME>_DATABASE_URL`
   secret per database. Optionally, add required reviewers there to approve
   each production run.
2. Protect `main`: require a pull request, and require the `verify` check.

## Conventions

`make db-check` enforces these. It runs before every migration, and in CI:

- Names are lowercase snake_case: databases, tables and columns.
- Every table has a `primary_key` and a `created_at` column.
- Timestamps are `timestamptz`, and their names end in `_at`.
- Boolean columns start with `is_` or `has_`.
- Foreign keys are named `<table>_<column>_fkey`.
- `migrations/` holds only Atlas-generated files.
- Every database has a line in `.env.example`.
- No other tool keeps migrations (Prisma, Alembic, Django...).

Also, by convention:

- Primary keys are `uuid default gen_random_uuid()`.
- Foreign keys use `on_delete = NO_ACTION` unless you mean otherwise.
- Foreign keys stay inside one database; refer to another service's rows by a
  plain `uuid`.

## Safety

- Migrations are never edited once committed; fix forward with a new one.
- Prefer expand, migrate, contract over destructive changes. For example, to
  rename a column: add the new column, switch the code over, and drop the old
  column in a later release.
- A failed migration stops the run. Databases after it are left untouched.
  Fix the cause and re-run; applied migrations are skipped.
- Two branches adding a migration to the same database will conflict in
  `atlas.sum`. After the first merges, update the second from `main`, delete
  its generated migration, and run `make db-migration` again.

## License

[MIT](LICENSE)
