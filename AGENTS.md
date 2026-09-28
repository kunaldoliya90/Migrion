# AGENTS.md

This repository is a centralized database schema and migration system for
microservices: one Postgres database per service, managed by Atlas. The
architecture is described in `README.md`.

## Database requests

For **any** request about databases, however it's phrased - creating one;
changing tables, columns or indexes; generating or applying migrations;
checking status; or setting the repo up - read `.vibe-code/database-change.md`
and follow it step by step. Don't improvise a different workflow.

The user should never have to run a command or edit a file. You do it, and
you stop for their approval only at the checkpoints the playbook defines.

## Non-negotiable

- Never install Atlas or any other tool. Atlas runs only in Docker or in CI.
- Never change or commit anything on `main`. Every change starts with
  `make db-branch` (branch `db/<database>/<change>`) and lands via a pull
  request.
- Schemas live only in `database/<name>/schema.hcl`. Migrations are generated
  (`make db-migration` with Docker, `make db-sync` without it) and never
  hand-written or edited.
- `make db-check` is the guardrail. Fix what it reports; never bypass, disable
  or edit it to make it pass.
- There are two environments: `local` and `production`. Production is
  migrated only by CI when a change reaches `main`, never from a workstation.
- Never commit `.env` or any credential.
