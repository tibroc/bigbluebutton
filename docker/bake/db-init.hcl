target "db-init" {
    inherits = ["docker-metadata-action", "_entrypoint-lib"]
    context = "./docker/db-init"
    contexts = {
        graphql-server = "./bbb-graphql-server"
        shared-notes-server = "./bbb-shared-notes-server"
    }
}
