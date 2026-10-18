target "_graphql-middleware-tags" {
    tags = bbb_image_tags("graphql-middleware")
}

target "graphql-middleware" {
    inherits = ["_graphql-middleware-tags", "docker-metadata-action", "_entrypoint-lib"]
    context = "./bbb-graphql-middleware"
    contexts = {
        bbb-yq-go = "./build/packages-template/bbb-yq-go"
    }
}
