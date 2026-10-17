target "_graphql-server-tags" {
    tags = bbb_image_tags("graphql-server")
}

target "graphql-server" {
    inherits = ["_graphql-server-tags", "docker-metadata-action", "_entrypoint-lib"]
    context = "./bbb-graphql-server"
    contexts = {
        graphql-server-pkg = "./build/packages-template/bbb-graphql-server"
        bbb-yq-go = "./build/packages-template/bbb-yq-go"
    }
}
