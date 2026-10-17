target "postgres" {
    inherits = ["docker-metadata-action"]
    context = "./docker/postgres"
    contexts = {
        graphql-server-pkg = "./build/packages-template/bbb-graphql-server"
    }
}
