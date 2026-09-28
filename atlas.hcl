// One generic environment for every service database. scripts/db.sh runs it
// (inside the atlas container) once per directory under database/, so
// creating database/<name>/ is all the registration a new database needs:
//
//   database/<name>/schema.hcl   desired state
//   database/<name>/migrations/  history
//   <NAME>_DATABASE_URL          connection (per environment), passed in as ATLAS_URL

variable "name" {
  type = string
}

variable "dev_url" {
  type = string
}

env "service" {
  src = "file://database/${var.name}/schema.hcl"
  url = getenv("ATLAS_URL")
  dev = var.dev_url
  migration {
    dir = "file://database/${var.name}/migrations"
  }
}
