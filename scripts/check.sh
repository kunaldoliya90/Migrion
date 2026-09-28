#!/usr/bin/env bash
# The guardrail: one way to name and shape every database. Prints one FAIL
# line per problem (with file and line) and exits 1 if there are any.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

failed=0
fail() { echo "FAIL $*"; failed=1; }

for dir in database/*/; do
  dir=${dir%/}
  [ -d "$dir" ] || continue
  db=$(basename "$dir")
  var="$(echo "$db" | tr '[:lower:]' '[:upper:]')_DATABASE_URL"

  [[ $db =~ ^[a-z][a-z0-9_]*$ ]] || fail "database/$db: name must be lowercase snake_case"
  [ -f "$dir/schema.hcl" ] || fail "database/$db/schema.hcl is missing"
  [ -d "$dir/migrations" ] || fail "database/$db/migrations/ is missing"
  grep -q "^$var=" .env.example || fail ".env.example: add a $var=... line"
  for f in "$dir"/migrations/*; do
    [ -e "$f" ] || continue
    [[ $(basename "$f") =~ ^([0-9]{14}_[a-z0-9_]+\.sql|atlas\.sum)$ ]] ||
      fail "$f: only Atlas-generated migrations belong in migrations/"
  done

  # Schema rules, checked per table and column.
  [ -f "$dir/schema.hcl" ] && awk -v file="$dir/schema.hcl" '
    function fail(n, msg) { printf "FAIL %s:%d: %s\n", file, n, msg; bad = 1 }
    function name(s) { sub(/^[^"]*"/, "", s); sub(/".*$/, "", s); return s }
    function end_column() {
      if (col == "") return
      if (type ~ /^timestamp/ && type != "timestamptz") fail(cline, col ": use timestamptz")
      if (type ~ /^timestamp/ && col !~ /_at$/) fail(cline, col ": timestamp columns end in _at")
      if (type == "boolean" && col !~ /^(is|has)_/) fail(cline, col ": boolean columns start with is_ or has_")
      if (col == "created_at") has_created = 1
      col = ""
    }
    function end_table() {
      if (table == "") return
      if (!has_pk) fail(tline, "table " table " needs a primary_key")
      if (!has_created) fail(tline, "table " table " needs a created_at column")
      table = ""
    }
    /^[ \t]*(#|\/\/)/ { next }
    /^[ \t]*table[ \t]+"/ {
      table = name($0); tline = NR; tdepth = depth; has_pk = 0; has_created = 0
      if (table !~ /^[a-z][a-z0-9_]*$/) fail(NR, "table " table " must be lowercase snake_case")
    }
    table != "" && /^[ \t]*column[ \t]+"/ {
      col = name($0); cline = NR; cdepth = depth; type = ""
      if (col !~ /^[a-z][a-z0-9_]*$/) fail(NR, "column " col " must be lowercase snake_case")
    }
    table != "" && /^[ \t]*primary_key/ { has_pk = 1 }
    table != "" && /^[ \t]*foreign_key[ \t]+"/ {
      if (name($0) !~ /_fkey$/) fail(NR, "foreign key " name($0) " must be named <table>_<column>_fkey")
    }
    col != "" && match($0, /type[ \t]*=[ \t]*[a-z_]+/) {
      type = substr($0, RSTART, RLENGTH); sub(/^type[ \t]*=[ \t]*/, "", type)
    }
    {
      line = $0
      depth += gsub(/[{]/, "", line) - gsub(/[}]/, "", line)
      if (col != "" && depth <= cdepth) end_column()
      if (table != "" && depth <= tdepth) end_table()
    }
    END { end_column(); end_table(); exit bad }
  ' "$dir/schema.hcl" || failed=1
done

# No other tool may own migrations.
others=$(find . \( -name .git -o -name node_modules -o -path ./database \) -prune -o \
  \( -path '*/prisma/migrations/*' -o -name alembic.ini -o -path '*/migrations/*.sql' -o -path '*/migrations/0*.py' \) -type f -print)
[ -z "$others" ] || fail "migrations outside database/: $others"

if [ "$failed" = 1 ]; then
  echo "Conventions check failed - fix the lines above (see README.md > Conventions)."
  exit 1
fi
echo "Conventions OK"
