target "_postgres-tags" {
    tags = bbb_image_tags("postgres")
}

target "postgres" {
    inherits = ["_postgres-tags", "docker-metadata-action"]
    context = "./docker/postgres"
    contexts = {
        graphql-server-pkg = "./build/packages-template/bbb-graphql-server"
    }
}
