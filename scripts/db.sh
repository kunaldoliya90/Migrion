#!/usr/bin/env bash
# The whole database workflow; every `make db-*` target wraps it.
# Atlas is never installed on a machine: it runs in Docker (docker-compose.yml)
# when Docker is available, and in GitHub Actions otherwise.
#
#   bash scripts/db.sh doctor                     check setup (fixes what's safe)
#   bash scripts/db.sh branch    <name> <change>  start db/<name>/<change> from the latest main
#   bash scripts/db.sh check                      guardrail: enforce the repo's conventions
#   bash scripts/db.sh new       <name>           scaffold database/<name>/
#   bash scripts/db.sh migration                  generate migrations from schema.hcl changes (Docker)
#   bash scripts/db.sh sync                       push, let CI generate migrations, pull them (no Docker)
#   bash scripts/db.sh migrate                    apply pending migrations to local databases (Docker)
#   bash scripts/db.sh migrate-prod               apply pending migrations to production (CI only)
#   bash scripts/db.sh status                     applied/pending migrations per local database (Docker)
#   bash scripts/db.sh verify    [base]           CI checks: conventions, branch, history, sync
set -u

NAME_RE='^[a-z][a-z0-9_]*$'
CHANGE_RE='^[a-z0-9]+(-[a-z0-9]+)*$'
DB_BRANCH_RE='^db/([a-z][a-z0-9_]*)/[a-z0-9]+(-[a-z0-9]+)*$'
DESTRUCTIVE_RE='DROP (TABLE|COLUMN|INDEX|CONSTRAINT|SCHEMA)|TRUNCATE|ALTER COLUMN .* TYPE'
NO_DOCKER_EXIT=3

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

if [ -t 1 ]; then
  BOLD=$'\033[1m' GREEN=$'\033[32m' YELLOW=$'\033[33m' RED=$'\033[31m' RESET=$'\033[0m'
else
  BOLD='' GREEN='' YELLOW='' RED='' RESET=''
fi

step()   { printf '\n%s==> %s%s\n' "$BOLD" "$*" "$RESET"; }
ok()     { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$*"; }
warn()   { printf '  %s!%s %s\n' "$YELLOW" "$RESET" "$*"; }
err()    { printf '  %s✗%s %s\n' "$RED" "$RESET" "$*"; }
die()    { err "$*"; exit 1; }
indent() { printf '%s\n' "$1" | sed -e '/community build of Atlas/,/More installation options/d' -e 's/^/      /'; }

services() {
  local d
  for d in database/*/; do
    [ -d "$d" ] && basename "$d"
  done
  return 0
}

url_var()  { printf '%s_DATABASE_URL' "$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"; }
url_of()   { local v; v=$(url_var "$1"); printf '%s' "${!v:-}"; }
count_sql() {
  local n=0 f
  for f in database/"$1"/migrations/*.sql; do [ -e "$f" ] && n=$((n + 1)); done
  echo "$n"
}
latest_sql() { ls database/"$1"/migrations/*.sql 2>/dev/null | sort | tail -1; }
append_line() {
  if [ -s "$1" ] && [ -n "$(tail -c1 "$1")" ]; then echo >> "$1"; fi
  printf '%s\n' "$2" >> "$1"
}
show_migration() {
  grep -E '^-- ' "$1" | sed 's/^-- /      /'
  if grep -iqE "$DESTRUCTIVE_RE" "$1"; then
    warn "DESTRUCTIVE - these statements can delete data:"
    indent "$(grep -inE "$DESTRUCTIVE_RE" "$1")"
    return 1
  fi
  return 0
}

# --- git --------------------------------------------------------------------

in_git()         { git rev-parse --git-dir >/dev/null 2>&1; }
current_branch() { git symbolic-ref -q --short HEAD 2>/dev/null; }
has_origin()     { git remote get-url origin >/dev/null 2>&1; }
default_branch() {
  local b
  if b=$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null); then echo "${b#origin/}"; return; fi
  if ! git show-ref -q --verify refs/heads/main && git show-ref -q --verify refs/heads/master; then echo master; return; fi
  echo main
}

require_branch() {
  in_git || return 0
  [ "${CI:-}" = true ] && return 0
  local cur
  cur=$(current_branch)
  [ "$cur" != "$(default_branch)" ] && return 0
  die "You're on $cur. Changes happen on a branch: make db-branch NAME=<database> CHANGE=<what-changes>"
}

enable_hooks() {
  in_git || return 0
  [ "$(git config --get core.hooksPath)" = .githooks ] && return 0
  git config core.hooksPath .githooks && ok "Enabled the repo's git hooks (commits on $(default_branch) are blocked)"
}

# --- environment ------------------------------------------------------------
# Two environments only: local (connection strings in .env) and production
# (connection strings only ever come from CI secrets; never read from a file).

load_env() {
  local line key val
  if [ ! -f .env ] && [ -f .env.example ]; then
    cp .env.example .env
    ok "Created .env from .env.example"
  fi
  [ -f .env ] || return 0
  # Parsed rather than sourced, so '&' or spaces in a URL can't run as shell.
  # Values already set in the shell take precedence over the file.
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    case "$line" in ''|'#'*) continue ;; *=*) ;; *) continue ;; esac
    key=${line%%=*}
    val=${line#*=}
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    [ -n "${!key:-}" ] && continue
    val=${val%\"}; val=${val#\"}; val=${val%\'}; val=${val#\'}
    export "$key=$val"
  done < .env
  ok "Loaded .env"
}

# --- docker / atlas ---------------------------------------------------------

have_docker() { docker info >/dev/null 2>&1; }
compose()     { docker compose --profile tools "$@"; }

no_docker() {
  warn "Docker isn't available here. Atlas never runs on this machine directly - only in Docker or in CI."
  echo "  $1"
  exit "$NO_DOCKER_EXIT"
}

DOCKER_READY=0
prepare_docker() {
  [ "$DOCKER_READY" = 1 ] && return 0
  local img
  for img in $(compose config --images 2>/dev/null); do
    docker image inspect "$img" >/dev/null 2>&1 && continue
    echo "  Downloading $img (first run only) ..."
    docker pull -q "$img" >/dev/null || die "Couldn't download $img."
  done
  if [ "$(uname -s)" = Linux ]; then
    HOST_UID=$(id -u); HOST_GID=$(id -g)
    export HOST_UID HOST_GID
  fi
  DOCKER_READY=1
}

DEV_STARTED=0
start_dev() {
  compose rm -sf atlas-dev >/dev/null 2>&1
  compose up -d --wait atlas-dev >/dev/null 2>&1 || die "Couldn't start the scratch Postgres container (atlas-dev)."
  DEV_STARTED=1
  trap stop_dev EXIT
  ok "Scratch database ready (throwaway container)"
}
stop_dev() {
  [ "$DEV_STARTED" = 1 ] && compose rm -sf atlas-dev >/dev/null 2>&1
  DEV_STARTED=0
}
dev_url_for() {
  compose exec -T atlas-dev createdb -U postgres "dev_$1" >/dev/null 2>&1 || die "Couldn't create a scratch database for $1."
  echo "postgres://postgres:postgres@atlas-dev:5432/dev_$1?sslmode=disable&search_path=public"
}

# Inside the container, "localhost" is the container itself; reach the host instead.
container_url() {
  printf '%s' "$1" | sed -E 's#^([a-z]+://([^@/]*@)?)(localhost|127\.0\.0\.1)([:/?]|$)#\1host.docker.internal\4#'
}

atlas_run() {
  local svc=$1 dev=$2
  shift 2
  ATLAS_URL=$(container_url "$(url_of "$svc")")
  export ATLAS_URL
  compose run --rm -T -e ATLAS_URL atlas "$@" --env service --var "name=$svc" --var "dev_url=$dev"
}

# Local only: start the compose Postgres if needed and create the service's
# database if it doesn't exist yet. Never used for production.
ensure_local_db() {
  local url=$1 rest host db running exists
  rest=${url#*://}; rest=${rest#*@}
  host=${rest%%/*}; host=${host%%:*}
  db=${rest#*/}; db=${db%%\?*}
  case "$host" in localhost|127.0.0.1) ;; *) return 0 ;; esac
  [[ "$db" =~ ^[A-Za-z0-9_]+$ ]] || return 0

  running=$(docker compose ps --status running --services 2>/dev/null)
  if ! grep -qx postgres <<<"$running"; then
    echo "      starting local Postgres (docker compose) ..."
    docker compose up -d --wait postgres >/dev/null 2>&1 ||
      warn "Couldn't start the compose Postgres (port 5432 taken?) - assuming a Postgres is already running there."
    running=$(docker compose ps --status running --services 2>/dev/null)
  fi
  grep -qx postgres <<<"$running" || return 0
  exists=$(docker compose exec -T -e DB="$db" postgres sh -c \
    'psql -U "$POSTGRES_USER" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = '\''$DB'\''"' 2>/dev/null | tr -d '[:space:]')
  if [ "$exists" != 1 ]; then
    docker compose exec -T -e DB="$db" postgres sh -c \
      'psql -U "$POSTGRES_USER" -d postgres -qc "CREATE DATABASE \"$DB\""' >/dev/null && ok "Created local database $db"
  fi
  return 0
}

# --- guardrail --------------------------------------------------------------

CHECK_FAILED=0
rule() { printf '  %sFAIL%s %s\n' "$RED" "$RESET" "$*"; CHECK_FAILED=1; }

check_schema() {
  awk -v file="$1" -v red="$RED" -v reset="$RESET" '
    function fail(n, msg) { printf "  %sFAIL%s %s:%d: %s\n", red, reset, file, n, msg; bad = 1 }
    function name_of(s) { sub(/^[^"]*"/, "", s); sub(/".*$/, "", s); return s }
    function close_column() {
      if (col == "") return
      if (ctype ~ /^timestamp/ && ctype != "timestamptz") fail(cline, "column \"" col "\": use timestamptz, not " ctype)
      if (ctype ~ /^timestamp/ && col !~ /_at$/) fail(cline, "column \"" col "\": timestamp columns must end in _at")
      if (ctype == "boolean" && col !~ /^(is|has)_/) fail(cline, "column \"" col "\": boolean columns must start with is_ or has_")
      if (col == "created_at") has_created = 1
      col = ""
    }
    function close_table() {
      if (table == "") return
      if (!has_pk) fail(tline, "table \"" table "\" must declare a primary_key block")
      if (!has_created) fail(tline, "table \"" table "\" must have a created_at column")
      table = ""
    }
    {
      line = $0
      sub(/\r$/, "", line)
      if (line ~ /^[ \t]*(#|\/\/)/) next
      if (line ~ /^[ \t]*table[ \t]+"/) {
        table = name_of(line); tline = NR; tdepth = depth; has_pk = 0; has_created = 0
        if (table !~ /^[a-z][a-z0-9_]*$/) fail(NR, "table \"" table "\" must be lowercase snake_case")
      } else if (table != "" && line ~ /^[ \t]*column[ \t]+"/) {
        col = name_of(line); cline = NR; cdepth = depth; ctype = ""
        if (col !~ /^[a-z][a-z0-9_]*$/) fail(NR, "column \"" col "\" must be lowercase snake_case")
      } else if (table != "" && line ~ /^[ \t]*primary_key[ \t]*[{]/) {
        has_pk = 1
      } else if (table != "" && line ~ /^[ \t]*foreign_key[ \t]+"/) {
        fk = name_of(line)
        if (fk !~ /_fkey$/) fail(NR, "foreign key \"" fk "\" must be named <table>_<column>_fkey")
      }
      if (col != "" && match(line, /type[ \t]*=[ \t]*[a-z_]+/)) {
        ctype = substr(line, RSTART, RLENGTH); sub(/^type[ \t]*=[ \t]*/, "", ctype)
      }
      depth += gsub(/[{]/, "{", line) - gsub(/[}]/, "}", line)
      if (col != "" && depth <= cdepth) close_column()
      if (table != "" && depth <= tdepth) close_table()
    }
    END { close_column(); close_table(); exit bad }
  ' "$1"
}

cmd_check() {
  step "Checking conventions"
  CHECK_FAILED=0
  local names s f b v n count=0 others
  names=$(services)
  for s in $names; do
    count=$((count + 1))
    if ! [[ "$s" =~ $NAME_RE ]] || [ "$s" = dev ]; then
      rule "database/$s: name must be lowercase snake_case (e.g. user_auth) and not 'dev'"
    fi
    [ -f "database/$s/schema.hcl" ] || rule "database/$s/schema.hcl is missing"
    [ -d "database/$s/migrations" ] || rule "database/$s/migrations/ is missing"
    for f in "database/$s/migrations/"*; do
      [ -e "$f" ] || continue
      b=${f##*/}
      [ "$b" = atlas.sum ] && continue
      [[ "$b" =~ ^[0-9]{14}_[a-z0-9_]+\.sql$ ]] ||
        rule "$f: only Atlas-generated <timestamp>_<name>.sql files and atlas.sum belong in migrations/"
    done
    if [ "$(count_sql "$s")" -gt 0 ] && [ ! -f "database/$s/migrations/atlas.sum" ]; then
      rule "database/$s/migrations/atlas.sum is missing - regenerate the migration"
    fi
    if [ -f .env.example ] && ! grep -q "^$(url_var "$s")=" .env.example; then
      rule ".env.example: missing a $(url_var "$s")=... line"
    fi
    if [ -f "database/$s/schema.hcl" ]; then
      check_schema "database/$s/schema.hcl" || CHECK_FAILED=1
    fi
  done

  if [ -f .env.example ]; then
    for v in $(grep -oE '^[A-Z0-9_]+_DATABASE_URL=' .env.example | sed 's/=$//'); do
      n=$(printf '%s' "${v%_DATABASE_URL}" | tr '[:upper:]' '[:lower:]')
      [ -d "database/$n" ] || rule ".env.example: $v has no matching database/$n/ directory"
    done
  elif [ -n "$names" ]; then
    rule ".env.example is missing"
  fi

  others=$(find . \( -name .git -o -name node_modules -o -name .venv -o -name venv -o -path ./database \) -prune -o \
    \( -path '*/prisma/migrations/*' -o -name alembic.ini -o -path '*/alembic/versions/*' -o -path '*/migrations/0*.py' -o -path '*/migrations/*.sql' \) \
    -type f -print 2>/dev/null)
  if [ -n "$others" ]; then
    rule "migrations found outside database/ - database/<name>/ is the only place migrations may live:"
    indent "$others"
  fi

  if [ "$CHECK_FAILED" = 1 ]; then
    echo
    err "Convention check failed. Fix every FAIL line above (see README.md > Conventions). Never bypass this check."
    return 1
  fi
  ok "$count database(s) follow the conventions"
}

# --- commands ---------------------------------------------------------------

cmd_branch() {
  local name=${1:-} change=${2:-} branch main dirty
  { [ -n "$name" ] && [ -n "$change" ]; } ||
    die "Usage: make db-branch NAME=<database> CHANGE=<what-changes>   (e.g. NAME=user_auth CHANGE=add-phone-verified)"
  [[ "$name" =~ $NAME_RE ]] || die "NAME '$name' must be lowercase snake_case (e.g. user_auth)."
  [[ "$change" =~ $CHANGE_RE ]] || die "CHANGE '$change' must be lowercase kebab-case (e.g. add-phone-verified)."
  in_git || die "Not a git repository."
  branch="db/$name/$change"
  main=$(default_branch)
  dirty=$(git status --porcelain)
  if [ -n "$dirty" ]; then
    err "You have uncommitted changes:"
    indent "$dirty"
    die "Commit or stash them first - nothing was switched."
  fi
  git rev-parse -q --verify "refs/heads/$main" >/dev/null || die "$main has no commits yet - make an initial commit on it first."

  step "Starting $branch"
  git switch -q "$main" || die "Couldn't switch to $main."
  if has_origin; then
    git pull -q --ff-only origin "$main" || die "Couldn't update $main from origin (does it have local commits?)."
    ok "$main is up to date with origin"
  else
    warn "No 'origin' remote - branching from local $main"
  fi
  if git rev-parse -q --verify "refs/heads/$branch" >/dev/null; then
    git switch -q "$branch" && ok "Switched to existing $branch"
  else
    git switch -q -c "$branch" && ok "Created $branch from $main"
  fi
  enable_hooks
}

cmd_new() {
  local name=${1:-} var line f
  [ -n "$name" ] || die "Usage: make db-new NAME=<name>"
  [[ "$name" =~ $NAME_RE ]] || die "'$name' is not a valid name: use lowercase letters, digits and underscores, starting with a letter (e.g. user_auth)."
  [ "$name" != dev ] || die "'dev' is reserved."
  [ ! -e "database/$name" ] || die "database/$name already exists."
  require_branch

  step "Creating database '$name'"
  mkdir -p "database/$name/migrations"
  printf 'schema "public" {}\n' > "database/$name/schema.hcl"
  ok "database/$name/schema.hcl and migrations/"
  var=$(url_var "$name")
  line="$var=postgres://postgres:postgres@localhost:5432/${name}_db?sslmode=disable"
  append_line .env.example "$line"
  ok ".env.example: $var"
  if [ -f .env ] && ! grep -q "^$var=" .env; then append_line .env "$line"; ok ".env: $var"; fi
  echo
  echo "  Next: add tables to database/$name/schema.hcl, then make db-migration (or make db-sync without Docker)"
  echo "  CI:   add a $var secret to the GitHub Environment 'production'"
}

cmd_migration() {
  local names s before out rc f total=0 destructive=0
  require_branch
  cmd_check || exit 1
  have_docker || no_docker "Commit your schema.hcl change, then run make db-sync: it pushes the branch, CI generates the migration and commits it back, and it's pulled here."
  step "Preparing"
  load_env
  prepare_docker
  names=$(services)
  [ -n "$names" ] || { ok "No databases yet - create one with: make db-new NAME=<name>"; return 0; }
  start_dev

  step "Generating migrations"
  for s in $names; do
    before=$(count_sql "$s")
    out=$(atlas_run "$s" "$(dev_url_for "$s")" migrate diff changes 2>&1); rc=$?
    if [ "$rc" -ne 0 ]; then
      err "$s: could not generate a migration"
      indent "$out"
      die "Stopped at '$s'. Nothing was applied to any database."
    fi
    if [ "$(count_sql "$s")" -gt "$before" ]; then
      f=$(latest_sql "$s")
      ok "$s: new migration $f"
      show_migration "$f" || destructive=1
      total=$((total + 1))
    else
      ok "$s: no schema changes"
    fi
  done

  step "Done"
  ok "$total new migration file(s)"
  [ "$destructive" = 0 ] || warn "Review the destructive statements above before applying them anywhere."
  [ "$total" = 0 ] || echo "  Next: make db-migrate"
}

cmd_sync() {
  local branch head waited=0 timeout=${DB_SYNC_TIMEOUT:-600} f
  in_git || die "Not a git repository."
  has_origin || die "No 'origin' remote - CI can only generate migrations for a pushed branch."
  require_branch
  cmd_check || exit 1
  [ -z "$(git status --porcelain database .env.example)" ] || die "Commit your database/ and .env.example changes first."
  branch=$(current_branch)
  head=$(git rev-parse HEAD)

  step "Pushing $branch"
  git push -q -u origin "$branch" || die "git push failed."
  ok "Pushed $(git log -1 --format=%h)"

  step "Waiting for CI to generate migrations (up to $((timeout / 60)) min)"
  while :; do
    git fetch -q origin "$branch" 2>/dev/null
    [ "$(git rev-parse "origin/$branch")" != "$head" ] && break
    [ "$waited" -ge "$timeout" ] &&
      die "Nothing arrived. Open the repo's Actions tab: the 'generate' job fails when the guardrail fails, and pushes nothing when no migration was needed."
    sleep 15
    waited=$((waited + 15))
    echo "      ... ${waited}s"
  done
  git merge -q --ff-only "origin/$branch" || die "Couldn't fast-forward to origin/$branch."
  ok "Pulled: $(git log -1 --format=%s)"
  for f in $(git diff --name-only --diff-filter=A "$head" HEAD -- 'database/*/migrations/*.sql'); do
    ok "$f"
    show_migration "$f"
  done
}

cmd_migrate() {
  cmd_check || exit 1
  have_docker || no_docker "Without Docker there's no local database. Production is migrated by CI when a change reaches main."
  step "Preparing local"
  load_env
  prepare_docker
  apply_all local
}

cmd_migrate_prod() {
  cmd_check || exit 1
  [ "${CI:-}" = true ] || die "Production is migrated only by CI, when a change reaches main - never from a workstation."
  step "Preparing production"
  prepare_docker
  apply_all production
}

apply_all() {
  local env=$1 names s out rc n missing="" failed="" summary="" where
  names=$(services)
  [ -n "$names" ] || { ok "No databases yet - create one with: make db-new NAME=<name>"; return 0; }
  for s in $names; do
    [ -n "$(url_of "$s")" ] || missing="$missing $(url_var "$s")"
  done
  if [ "$env" = local ]; then where=".env"; else where="the secrets of the GitHub Environment 'production'"; fi
  [ -z "$missing" ] || die "Not set:$missing - add to $where."

  step "Applying migrations ($env)"
  for s in $names; do
    if [ -n "$failed" ]; then
      summary+=$(printf '  %-24s %s' "$s" "not run")$'\n'
      continue
    fi
    [ "$env" = local ] && ensure_local_db "$(url_of "$s")"
    out=$(atlas_run "$s" unused migrate apply 2>&1); rc=$?
    if [ "$rc" -ne 0 ]; then
      err "$s: FAILED"
      indent "$out"
      failed=$s
      summary+=$(printf '  %-24s %s' "$s" "FAILED")$'\n'
    elif grep -q "No migration files to execute" <<<"$out"; then
      ok "$s: already up to date"
      summary+=$(printf '  %-24s %s' "$s" "up to date")$'\n'
    else
      n=$(grep -cE '^ *-- migrating version' <<<"$out")
      ok "$s: applied $n migration(s)"
      grep -E '^ *-- migrating version' <<<"$out" | sed 's/^ *-- /      /'
      summary+=$(printf '  %-24s %s' "$s" "applied $n")$'\n'
    fi
  done

  step "Summary ($env)"
  printf '%s' "$summary"
  [ -z "$failed" ] || die "'$failed' failed ($env); databases after it were not touched. Fix the error above and re-run - applied migrations are skipped automatically."
  ok "Every $env database is up to date"
}

cmd_status() {
  local names s out rc bad=0 state current pending
  have_docker || no_docker "Production status is in CI: every migrate run prints a per-database summary (repo Actions tab)."
  step "Preparing local"
  load_env
  prepare_docker
  names=$(services)
  [ -n "$names" ] || { ok "No databases yet"; return 0; }

  step "Migration status (local)"
  for s in $names; do
    if [ -z "$(url_of "$s")" ]; then err "$s: $(url_var "$s") is not set"; bad=1; continue; fi
    out=$(atlas_run "$s" unused migrate status 2>&1); rc=$?
    if [ "$rc" -ne 0 ]; then err "$s: can't read status"; indent "$out"; bad=1; continue; fi
    state=$(sed -n 's/^Migration Status: *//p' <<<"$out")
    current=$(sed -n 's/^ *-- Current Version: *//p' <<<"$out")
    pending=$(sed -n 's/^ *-- Pending Files: *//p' <<<"$out")
    if [ "$state" = OK ]; then
      ok "$s: up to date (version $current)"
    else
      warn "$s: $pending pending (current: $current) - run make db-migrate"
    fi
  done
  return $bad
}

cmd_doctor() {
  local problems=0 names s out cur
  step "Tools"
  ok "bash $BASH_VERSION"
  if command -v git >/dev/null 2>&1; then ok "$(git --version)"; else die "git is required."; fi
  if command -v make >/dev/null 2>&1; then ok "make"; else warn "make not found - use 'bash scripts/db.sh <command>' instead of 'make db-<command>'"; fi
  if have_docker; then
    ok "Docker is running - Atlas runs locally in a container"
    prepare_docker
  elif command -v docker >/dev/null 2>&1; then
    warn "Docker is installed but not running - start it to work locally, or let CI do it (make db-sync)"
  else
    ok "No Docker - fine: CI generates migrations (make db-sync) and migrates production"
  fi

  step "Repository"
  if in_git; then
    cur=$(current_branch)
    if [ "$cur" = "$(default_branch)" ]; then ok "On $cur - start any change with make db-branch"; else ok "On branch $cur"; fi
    if has_origin; then ok "origin: $(git remote get-url origin)"; else warn "No 'origin' remote - pushing, CI and make db-sync need one"; fi
    enable_hooks
  else
    warn "Not a git repository"
  fi

  step "Configuration"
  load_env
  names=$(services)
  if [ -n "$names" ]; then ok "Databases: $(echo $names)"; else ok "No databases yet - create one with: make db-new NAME=<name>"; fi
  cmd_check || problems=$((problems + 1))

  if [ -n "$names" ] && have_docker; then
    step "Connectivity (local)"
    for s in $names; do
      if [ -z "$(url_of "$s")" ]; then
        err "$s: $(url_var "$s") is not set in .env"
        problems=$((problems + 1))
        continue
      fi
      ensure_local_db "$(url_of "$s")"
      if out=$(atlas_run "$s" unused migrate status 2>&1); then
        ok "$s: reachable ($(sed -n 's/^Migration Status: *//p' <<<"$out"))"
      else
        err "$s: cannot connect"
        indent "$out"
        problems=$((problems + 1))
      fi
    done
  fi

  step "Result"
  [ "$problems" -eq 0 ] || die "$problems problem(s) found above."
  ok "Ready."
}

cmd_verify() {
  local base=${1:-} changed added f destructive="" names s before drift="" dbs target labels
  cmd_check || exit 1

  step "Checking branch and migration history"
  if [ -n "$base" ] && git rev-parse --verify -q "$base^{commit}" >/dev/null 2>&1; then
    dbs=$(git diff --name-only "$base"...HEAD -- database/ | awk -F/ 'NF > 2 { print $2 }' | sort -u)
    if [ -n "${DB_BRANCH:-}" ] && [ -n "$dbs" ]; then
      [[ "$DB_BRANCH" =~ $DB_BRANCH_RE ]] ||
        die "Database changes must come from a branch named db/<database>/<change> (e.g. db/$(echo $dbs | cut -d' ' -f1)/add-something), not '$DB_BRANCH'."
      target=${BASH_REMATCH[1]}
      for s in $dbs; do
        [ "$s" = "$target" ] || die "Branch $DB_BRANCH may only change database/$target/, but it also changes database/$s/. One database per branch."
      done
      ok "Branch $DB_BRANCH only changes database/$target/"
    fi

    changed=$(git diff --name-only --diff-filter=MDR "$base"...HEAD -- 'database/*/migrations/*.sql')
    if [ -n "$changed" ]; then
      err "Committed migration files were edited, renamed or deleted:"
      indent "$changed"
      die "Migrations are immutable once committed. Revert those changes and fix forward with a new schema.hcl change."
    fi
    ok "No committed migration was modified"

    if [ "${ALLOW_DESTRUCTIVE:-}" = lookup ]; then
      ALLOW_DESTRUCTIVE=false
      if command -v gh >/dev/null 2>&1 && [ -n "${DB_BRANCH:-}" ]; then
        labels=$(gh pr view "$DB_BRANCH" --json labels -q '.labels[].name' 2>/dev/null)
        grep -qx allow-destructive-migration <<<"$labels" && ALLOW_DESTRUCTIVE=true
      fi
    fi
    if [ -n "${ALLOW_DESTRUCTIVE:-}" ]; then
      added=$(git diff --name-only --diff-filter=A "$base"...HEAD -- 'database/*/migrations/*.sql')
      for f in $added; do
        grep -iqE "$DESTRUCTIVE_RE" "$f" && destructive="$destructive $f"
      done
      if [ -n "$destructive" ] && [ "$ALLOW_DESTRUCTIVE" != true ]; then
        die "Destructive migration(s):$destructive - after review, add the PR label 'allow-destructive-migration' to approve."
      fi
      if [ -n "$destructive" ]; then warn "Destructive migration(s) approved by label:$destructive"; else ok "No destructive migrations added"; fi
    fi
  else
    warn "No base revision - skipping branch and history checks"
  fi

  step "Checking schema.hcl and migrations are in sync"
  have_docker || no_docker "This check runs in CI on every pull request."
  load_env
  prepare_docker
  names=$(services)
  [ -n "$names" ] || { ok "No databases yet"; return 0; }
  start_dev
  for s in $names; do
    before=$(count_sql "$s")
    [ -f "database/$s/migrations/atlas.sum" ] && cp "database/$s/migrations/atlas.sum" "$ROOT/.atlas.sum.bak"
    atlas_run "$s" "$(dev_url_for "$s")" migrate diff changes >/dev/null 2>&1 ||
      die "$s: Atlas could not read the schema or migrations - run make db-migration to see why."
    if [ "$(count_sql "$s")" -gt "$before" ]; then
      drift="$drift $s"
      rm -f "$(latest_sql "$s")"
      if [ -f .atlas.sum.bak ]; then mv .atlas.sum.bak "database/$s/migrations/atlas.sum"; else rm -f "database/$s/migrations/atlas.sum"; fi
    fi
    rm -f .atlas.sum.bak
  done
  [ -z "$drift" ] || die "schema.hcl changed without a migration for:$drift - run make db-migration (or make db-sync) and commit the result."
  ok "Every schema.hcl matches its migrations"
}

case "${1:-}" in
  doctor)       cmd_doctor ;;
  branch)       cmd_branch "${2:-}" "${3:-}" ;;
  check)        cmd_check ;;
  new)          cmd_new "${2:-}" ;;
  migration)    cmd_migration ;;
  sync)         cmd_sync ;;
  migrate)      cmd_migrate ;;
  migrate-prod) cmd_migrate_prod ;;
  status)       cmd_status ;;
  verify)       cmd_verify "${2:-}" ;;
  *) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
