# database/

Every service's database schema and migration history, managed by
[Atlas](https://atlasgo.io). One directory per database:

```
database/<name>/
├── schema.hcl     desired state - edit this
└── migrations/    generated SQL history + atlas.sum - never edit
```

Creating a directory here (`make db-new NAME=<name>`) is all it takes to
register a new database. Changes always happen on a `db/<name>/<change>`
branch:

```bash
make db-branch NAME=<name> CHANGE=<what-changes>
make db-migration   # generate migrations (Docker), or: make db-sync (CI does it)
make db-migrate     # apply locally (Docker)
```

See [README.md](../README.md) for branches, environments, CI, conventions
and safety rules.
