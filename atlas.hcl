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
