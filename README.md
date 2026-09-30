# Migrion

[![Test](https://github.com/kunaldoliya90/Migrion/actions/workflows/test.yml/badge.svg)](https://github.com/kunaldoliya90/Migrion/actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**One repository for every microservice's database schema and migrations.**

Migrion keeps the Postgres schemas of all your services in one place, generates
their migrations with [Atlas](https://atlasgo.io), and ships them to production
through GitHub Actions. Your services can be written in any language, and none
of them has to own migrations anymore.

## Why

When every service manages its own migrations (Prisma here, Alembic there,
Django elsewhere), a schema change means a different tool and different
commands in every repo. Migrion replaces all of that with one workflow:

```
edit schema.hcl  →  make db-migration  →  pull request  →  merged = in production
```

- **Declarative.** You describe what each database should look like; Atlas
  writes the SQL.
- **Nothing to install.** Atlas and Postgres run in Docker.
- **Safe by default.** Conventions are checked on every change. Committed
  migrations can't be edited. Destructive changes need explicit approval, and
  production is only ever migrated by CD.
- **Small.** A Makefile, two short scripts, two workflows. Easy to read, easy
  to change.
- **Agent-friendly.** Any AI coding agent can drive it through `AGENTS.md`.

## Requirements

- [Git](https://git-scm.com)
- [Docker](https://docs.docker.com/get-docker/) with Compose v2
- `make` (optional: every target is also `bash scripts/db.sh <command>`)

On Windows, use Git Bash.

## Getting started

1. Click **Use this template** on GitHub (or clone the repo), then run:

   ```bash
   make setup
   ```

   This creates your `.env`, enables a git hook that blocks commits on `main`,
   and starts a local Postgres.

2. Add your first database:

   ```bash
   make db-branch NAME=billing CHANGE=create
   make db-new NAME=billing
   ```

3. Describe its tables in `database/billing/schema.hcl`:

   ```hcl
   schema "public" {}

   table "invoices" {
     schema = schema.public
     column "id" {
       type    = uuid
       default = sql("gen_random_uuid()")
     }
     column "amount" {
       type = numeric(12,2)
     }
     column "is_paid" {
       type    = boolean
       default = false
     }
     column "created_at" {
       type    = timestamptz
       default = sql("now()")
     }
     primary_key {
       columns = [column.id]
     }
   }
   ```

4. Generate the migration, then apply it locally:

   ```bash
   make db-migration
   make db-migrate
   ```

5. Commit, push, and open a pull request:

   ```bash
   git add -A
   git commit -m "db(billing): create"
   git push -u origin HEAD
   ```

   CI checks the pull request. Merging it lets CD migrate production.

## Everyday workflow

**Change a schema:**

```bash
make db-branch NAME=billing CHANGE=add-due-date
# edit database/billing/schema.hcl
make db-migration
make db-migrate
```

Then commit and open a pull request.

**Add another database:** same as steps 2–5 above.

**Check what's applied locally:** `make db-status`

## Commands

| Command | What it does |
|---|---|
| `make setup` | Creates `.env`, enables the git hook, starts the local Postgres |
| `make db-branch NAME=x CHANGE=y` | Updates `main` and creates the branch `db/x/y` |
| `make db-new NAME=x` | Creates `database/x/` and registers `X_DATABASE_URL` |
| `make db-check` | Checks naming and schema conventions |
| `make db-migration` | Generates migrations from `schema.hcl` changes and warns about destructive ones |
| `make db-migrate` | Applies pending migrations to your local databases |
| `make db-status` | Shows applied and pending migrations locally |
| `make db-migrate-prod` | Applies pending migrations to production (CD only) |

## Environments

There are two:

| | Connection strings | Migrated by |
|---|---|---|
| **local** | `.env`, created from `.env.example` and never committed | you, with `make db-migrate` |
| **production** | Secrets on the GitHub Environment `production` | CD, when a change reaches `main` |

Every database has one variable, `<NAME>_DATABASE_URL`. `make db-new` adds the
local one for you:

```
BILLING_DATABASE_URL="postgres://postgres:postgres@postgres:5432/billing?sslmode=disable"
```

The host `postgres` is the local Postgres container, as Atlas sees it. Your
own apps reach the same databases at `localhost:5432`. If port 5432 is already
taken on your machine, set `POSTGRES_PORT` in `.env`.

## CI and CD

**CI** (`.github/workflows/ci.yml`) runs on every pull request and fails if:

- a convention is broken;
- a committed migration was edited;
- a `schema.hcl` change has no migration;
- a migration is destructive and the PR doesn't have the label
  `allow-destructive-migration`.

**CD** (`.github/workflows/cd.yml`) runs when `database/` changes on `main`,
and applies all pending migrations to production. You can also start it from
the Actions tab.

### One-time GitHub setup

1. **Settings → Environments →** create `production`. Add one secret per
   database, named `<NAME>_DATABASE_URL`. Optionally, add required reviewers
   to approve each production run.
2. **Settings → Branches →** protect `main`: require a pull request, and
   require the `verify` status check.
3. **Network access.** CD runs on GitHub-hosted runners, so they must be able
   to reach your production databases. If your databases are on a private
   network, use a [self-hosted runner](https://docs.github.com/actions/hosting-your-own-runners)
   inside it (change `runs-on` in `cd.yml`) or allow GitHub's IP ranges.
4. **Delete `.github/workflows/test.yml`.** It tests Migrion itself and is
   skipped outside this repository.

## Conventions

`make db-check` enforces these on every migration and in CI:

- Databases, tables and columns use lowercase `snake_case`.
- Every table has a `primary_key` and a `created_at` column.
- Timestamp columns are `timestamptz`, and their names end in `_at`.
- Boolean columns start with `is_` or `has_`.
- Foreign keys are named `<table>_<column>_fkey`.
- `migrations/` contains only Atlas-generated files.
- Every database has a line in `.env.example`.
- No other tool keeps migrations in the repo (Prisma, Alembic, Django, …).

Recommended, but not enforced:

- Use `uuid` primary keys with `default gen_random_uuid()`.
- Use `on_delete = NO_ACTION` on foreign keys unless you mean otherwise.
- Never add foreign keys across databases. Refer to another service's rows by
  a plain `uuid`.

## Safety

- **Never edit a committed migration.** Fix forward with a new one.
- **Avoid destructive changes in one step.** Use expand → migrate → contract.
  To rename a column: add the new column, switch the code over, and drop the
  old column in a later release.
- **Failures stop the run.** If one database fails, the ones after it are not
  touched. Fix the cause and re-run; applied migrations are skipped.
- **Parallel branches.** Two branches that both add a migration to the same
  database conflict in `atlas.sum`. After the first merges, update the second
  from `main`, delete its generated migration, and run `make db-migration`
  again.

## Limitations

- **Postgres only**, and only the `public` schema of each database.
- **The destructive-change check is a text match** on `DROP`, `TRUNCATE` and
  column type changes. It catches the common cases, not every way to lose
  data, so still read each generated migration.
- **Migrations run in order, one database at a time.** There is no rollback;
  a failed migration is fixed forward with a new one.
- Uses the free Atlas community edition, so Pro-only features such as
  `migrate lint` are not used.

## Project structure

```
database/<name>/schema.hcl    the desired state of a database - edit this
database/<name>/migrations/   generated SQL history and atlas.sum - never edit
atlas.hcl                     the Atlas configuration shared by all databases
docker-compose.yml            local Postgres, Atlas, and a scratch Postgres
Makefile                      the commands
scripts/db.sh                 what the commands do
scripts/check.sh              the conventions check
.githooks/pre-commit          blocks commits on main
.github/workflows/            CI and CD
AGENTS.md, .vibe-code/        instructions for AI coding agents
```

## Using an AI coding agent

Open the repo in Claude Code, Cursor, Copilot, Codex or Gemini and ask for
what you want, e.g. *"add a billing database with invoices and payments"*.
The agent follows `AGENTS.md` and `.vibe-code/database-change.md`:

1. It creates a branch.
2. It shows you a plan.
3. It writes the schema.
4. It generates and applies the migration.
5. It opens the pull request.

## Contributing

Issues and pull requests are welcome. Work on a branch (`feat/…`, `fix/…`,
`docs/…`) and keep changes small. Every pull request runs `test.yml`, which
lints the scripts with ShellCheck and runs the full workflow against a
throwaway database.

To report a security issue, please use
[GitHub's private vulnerability reporting](https://github.com/kunaldoliya90/Migrion/security/advisories/new)
instead of opening a public issue.

## License

[MIT](LICENSE)
