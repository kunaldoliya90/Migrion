#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1

if [ "$(uname)" = Linux ]; then
  HOST_UID=$(id -u)
  HOST_GID=$(id -g)
  export HOST_UID HOST_GID
fi

databases() {
  local f
  for f in database/*/schema.hcl; do
    [ -e "$f" ] && basename "$(dirname "$f")"
  done
  return 0
}

url_var() { echo "$(echo "$1" | tr '[:lower:]' '[:upper:]')_DATABASE_URL"; }

load_local_env() {
  [ -f .env ] || cp .env.example .env
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
}

atlas() {
  local db=$1
  shift
  docker compose run --rm -T -e "$(url_var "$db")" atlas "$@" --env db --var "name=$db"
}

cmd_setup() {
  load_local_env
  git config core.hooksPath .githooks
  docker compose up -d --wait postgres
  echo "Ready. Local Postgres is on localhost:${POSTGRES_PORT:-5432}."
}

cmd_branch() {
  local db=${1:-} change=${2:-}
  { [ -n "$db" ] && [ -n "$change" ]; } || { echo "usage: make db-branch NAME=<database> CHANGE=<what-changes>"; exit 1; }
  { git diff --quiet && git diff --cached --quiet; } || { echo "Commit or stash your changes first."; exit 1; }
  git switch main
  git pull --ff-only
  git switch -c "db/$db/$change"
}

cmd_new() {
  local db=${1:-} line
  [ -n "$db" ] || { echo "usage: make db-new NAME=<database>"; exit 1; }
  [[ $db =~ ^[a-z][a-z0-9_]*$ ]] || { echo "'$db': use lowercase snake_case, e.g. user_auth."; exit 1; }
  [ ! -e "database/$db" ] || { echo "database/$db already exists."; exit 1; }
  load_local_env
  mkdir -p "database/$db/migrations"
  touch "database/$db/migrations/.gitkeep"
  echo 'schema "public" {}' > "database/$db/schema.hcl"
  line="$(url_var "$db")=\"postgres://postgres:postgres@postgres:5432/$db?sslmode=disable\""
  echo "$line" >> .env.example
  echo "$line" >> .env
  echo "Created database/$db/. Add tables to its schema.hcl, then run make db-migration."
}

cmd_migration() {
  local db f destructive='DROP (TABLE|COLUMN|INDEX|CONSTRAINT)|TRUNCATE|ALTER COLUMN .* TYPE'
  load_local_env
  bash scripts/check.sh
  docker compose up -d --wait atlas-dev
  for db in $(databases); do
    echo "==> $db"
    docker compose exec -T -e PGOPTIONS="-c client_min_messages=warning" atlas-dev psql -U postgres -q \
      -c "DROP DATABASE IF EXISTS \"$db\"" -c "CREATE DATABASE \"$db\""
    atlas "$db" migrate diff changes
    for f in $(git ls-files --others --exclude-standard "database/$db/migrations/*.sql"); do
      echo "  new: $f"
      if grep -iqE "$destructive" "$f"; then
        echo "  WARNING: this migration can delete data - review it before applying:"
        grep -inE "$destructive" "$f" | sed 's/^/    /'
      fi
    done
  done
}

cmd_migrate() {
  local db
  load_local_env
  bash scripts/check.sh
  docker compose up -d --wait postgres
  for db in $(databases); do
    echo "==> $db"
    docker compose exec -T postgres psql -U postgres -tAc "SELECT 1 FROM pg_database WHERE datname = '$db'" | grep -q 1 ||
      docker compose exec -T postgres createdb -U postgres "$db"
    atlas "$db" migrate apply || { echo "✗ $db failed; databases after it were not migrated."; exit 1; }
  done
}

cmd_status() {
  local db
  load_local_env
  docker compose up -d --wait postgres
  for db in $(databases); do
    echo "==> $db"
    atlas "$db" migrate status
  done
}

cmd_migrate_prod() {
  local db var
  [ "${CI:-}" = true ] || { echo "Production is migrated by CD only, never from a workstation."; exit 1; }
  bash scripts/check.sh
  for db in $(databases); do
    var=$(url_var "$db")
    [ -n "${!var:-}" ] || { echo "✗ $var is not set - add it as a secret on the GitHub Environment 'production'."; exit 1; }
    echo "==> $db"
    atlas "$db" migrate apply || { echo "✗ $db failed; databases after it were not migrated."; exit 1; }
  done
}

case "${1:-}" in
  setup)        cmd_setup ;;
  branch)       cmd_branch "${2:-}" "${3:-}" ;;
  new)          cmd_new "${2:-}" ;;
  check)        bash scripts/check.sh ;;
  migration)    cmd_migration ;;
  migrate)      cmd_migrate ;;
  status)       cmd_status ;;
  migrate-prod) cmd_migrate_prod ;;
  *) echo "usage: bash scripts/db.sh setup|branch|new|check|migration|migrate|status|migrate-prod"; exit 1 ;;
esac
