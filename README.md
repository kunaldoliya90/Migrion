# Migrion

Centralized database schemas and migrations for microservices. One repo holds
every service's Postgres schema and migration history, managed by
[Atlas](https://atlasgo.io). Services can be written in any language, and none
of them owns migrations.

## Get started

1. Click **Use this template** on GitHub, or clone the repo.
2. Open it with any coding agent and say *"set this up"* or *"add a database
   for my billing service"*. The agent does the rest.

To do it by hand, run `make db-doctor`, then follow "The workflow" below.

**Nothing to install.** Atlas never runs on your machine directly:

- **With Docker:** Atlas runs in a container defined in `docker-compose.yml`.
- **Without Docker:** Atlas runs in GitHub Actions.

All you need is git and bash (Git Bash on Windows).

**Working with an AI agent?** Just ask it. Any coding agent reads `AGENTS.md`,
which points it to `.vibe-code/database-change.md`, and it handles the rest.

## The workflow

Every change goes through a branch and a pull request, never straight to `main`.

```bash
make db-branch NAME=user_auth CHANGE=add-phone-verified   # latest main -> db/user_auth/add-phone-verified
# edit database/user_auth/schema.hcl
make db-migration && make db-migrate    # with Docker: generate, then apply locally
make db-sync                            # without Docker: push; CI generates the migration and it's pulled back
# open a pull request; merging migrates the target environment
```

No `make`? Every target is `bash scripts/db.sh <command>` underneath, so for
example `bash scripts/db.sh branch user_auth add-phone-verified`.

## Layout

```
atlas.hcl                  one generic Atlas environment, used for every database
database/<name>/
  schema.hcl               desired state of that database (edit this)
  migrations/              generated SQL history + atlas.sum checksum (never edit)
scripts/db.sh              the whole workflow; the Makefile wraps it
docker-compose.yml         Postgres + Atlas + a scratch Postgres, as containers
.env.example               local connection strings, one <NAME>_DATABASE_URL per database
.githooks/pre-commit       blocks commits on main (enabled by make db-doctor / db-branch)
.github/workflows/         CI: generate, verify, migrate
AGENTS.md, .vibe-code/     instructions for coding agents
```

Creating `database/<name>/` is the only registration a database needs. Atlas
runs once per directory, reading the connection from `<NAME>_DATABASE_URL`.

## Commands

| Command | Needs Docker | What it does |
|---|---|---|
| `make db-doctor` | no | Checks tools, repo, conventions and connectivity, and fixes what's safe: creates `.env`, enables the git hook, starts the local Postgres, creates local databases. |
| `make db-branch NAME=x CHANGE=y` | no | Updates `main` from origin and creates `db/x/y`. |
| `make db-new NAME=x` | no | Scaffolds `database/x/` and adds `X_DATABASE_URL` to `.env.example` and `.env`. |
| `make db-migration` | yes | Generates migrations for changed schemas, and flags destructive statements. |
| `make db-sync` | no | Pushes the branch, waits for CI to commit the generated migrations, and pulls them. |
| `make db-migrate` | yes | Applies pending migrations to your local databases. |
| `make db-status` | yes | Applied and pending migrations per local database. |
| `make db-check` | no | The guardrail (see Conventions). Runs automatically. |
| `make db-migrate-prod` | - | Applies pending migrations to production. CI only; refuses to run anywhere else. |
| `make db-verify [BASE=ref]` | yes | What CI runs on every PR. |

Output marks each result ✓ (ok), ! (warning) or ✗ (failed). Exit code 3 means
"needs Docker"; the message says what to do instead.

## Branches

- **Database changes:** `db/<database>/<change>`, e.g.
  `db/user_auth/add-phone-verified` or `db/billing/create`. `<database>` is
  snake_case and `<change>` is kebab-case. **One database per branch.**
- **Everything else:** `feat/<change>`, `fix/<change>`, `chore/<change>`,
  `docs/<change>`.

Enforced three ways:

- `make db-new` and `make db-migration` refuse to run on `main`.
- The pre-commit hook blocks commits on `main`.
- CI rejects a PR that touches `database/` from a badly named branch, or that
  changes more than one database.

Also protect `main` on GitHub: require a pull request, and require the
`verify` check to pass.

## Environments

There are two, and both use the same variable names, one
`<NAME>_DATABASE_URL` per database:

| Environment | Where the URLs live | Who migrates it |
|---|---|---|
| **local** | `.env` (gitignored, created from `.env.example`) | you: `make db-migrate` (Docker) |
| **production** | secrets on the GitHub Environment `production` | CI only, when a change reaches `main` |

Production is never migrated from a workstation, and its credentials never
touch a file in the repo.

## CI

`.github/workflows/database-migration.yml` has three jobs.

- **generate** runs on every push to a branch other than `main`. It creates
  migrations for any `schema.hcl` change and commits them back to the branch
  as `db: generate migrations`, which is what makes the no-Docker workflow
  work.
- **verify** runs on every PR, and before every production migrate. It
  checks:
  - the branch name, and that the branch changes only one database;
  - conventions (the guardrail);
  - that no committed migration was edited, renamed or deleted;
  - that every `schema.hcl` matches its migrations;
  - that any destructive migration has been approved with the PR label
    `allow-destructive-migration`.
- **migrate-production** runs on push to `main`. To re-run it, use the
  Actions tab (*Run workflow* on `main`). It loads every `*_DATABASE_URL`
  secret from the GitHub Environment `production` automatically, so adding a
  database never means editing the workflow.

Recommended repo setup:

- A GitHub Environment named `production`, with each database's
  `<NAME>_DATABASE_URL` as a secret, and required reviewers if you want a
  manual approval before each production migration.
- Branch protection on `main`, as above.

## Without Docker

Nothing changes except where Atlas runs:

- `make db-sync` pushes your branch; the `generate` job creates the migration
  and commits it back, and `db-sync` pulls it.
- PR checks run in CI as usual.
- Merging migrates production.

There is no local database without Docker.

## Conventions (enforced)

One way to do everything, checked by `make db-check`. It runs before every
migration and migrate, and in CI. It fails, naming the file and line, when:

- a database, table or column name isn't lowercase snake_case;
- a table has no `primary_key` or no `created_at` column;
- a timestamp column isn't `timestamptz`, or its name doesn't end in `_at`;
- a boolean column doesn't start with `is_` or `has_`;
- a foreign key isn't named `<table>_<column>_fkey`;
- `migrations/` contains anything but Atlas-generated `<timestamp>_<name>.sql`
  files and `atlas.sum`, or `atlas.sum` is missing;
- `.env.example` is missing a database's URL, or lists one with no directory;
- migrations exist outside `database/` (Prisma, Alembic, Django, raw SQL...).

Beyond what the guardrail can check:

- **Primary keys:** `uuid default gen_random_uuid()` unless there's a reason
  to differ.
- **Foreign keys:** `on_delete = NO_ACTION` unless you choose otherwise.
- **Status fields:** `varchar(32)` with UPPERCASE defaults instead of enums.
- **Foreign-key columns:** indexed.

The full list agents apply is in `.vibe-code/database-change.md`.

## Safety

- **Migrations are immutable once committed.** Fix forward with a new one; CI
  rejects edits to old ones.
- **Destructive changes** (`DROP TABLE/COLUMN/INDEX/CONSTRAINT`, `TRUNCATE`,
  type changes) are flagged when generated, and blocked in CI until the PR is
  labelled `allow-destructive-migration`. Prefer expand -> migrate ->
  contract: add the new column, switch the code over, and drop the old one in
  a later release, so a rolling deploy never breaks the running version.
- **No automatic rollback.** A failed migration stops the run and reports the
  error.
- **Keep each service's database independent.** No foreign keys across
  databases. Refer to another service's rows by a plain `uuid`.
- **Line endings.** `.gitattributes` keeps every file LF, because Atlas
  checksums migrations byte-for-byte.

## When a migration fails

Databases are migrated one at a time, in alphabetical order. The first failure
stops the run with Atlas's error, and the rest are reported as `not run`:

```
  auth                     up to date
  billing                  FAILED
  jobs                     not run
```

Fix the cause and re-run. Migrations that were already applied are skipped
automatically.

## Two branches, same database

`atlas.sum` is a chain, so two PRs that both add a migration to the same
database will conflict. After the first one merges, update the second:

1. Merge `main` into it.
2. Take `main`'s `atlas.sum`, and delete the branch's own generated migration.
3. Regenerate, with `make db-migration` or `make db-sync`.

## Your first database

Start with `make db-branch NAME=<yours> CHANGE=create`, then
`make db-new NAME=<yours>`. Everything else is generic.

## License

[MIT](LICENSE)
