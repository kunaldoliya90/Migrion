// One environment for every database. scripts/db.sh runs it once per folder
// under database/, passing the folder name as `name`.
//   schema.hcl         what the database should look like
//   migrations/        the generated history
//   <NAME>_DATABASE_URL where the database is (.env locally, secrets in CD)

variable "name" {
  type = string
}

env "db" {
  src = "file://database/${var.name}/schema.hcl"
  url = getenv("${upper(var.name)}_DATABASE_URL")
  dev = "postgres://postgres:postgres@atlas-dev:5432/${var.name}?sslmode=disable&search_path=public"
  migration {
    dir = "file://database/${var.name}/migrations"
  }
}
