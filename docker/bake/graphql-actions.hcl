target "_graphql-actions-tags" {
    tags = bbb_image_tags("graphql-actions")
}

target "graphql-actions" {
    inherits = ["_graphql-actions-tags", "docker-metadata-action"]
    context = "./bbb-graphql-actions"
}
