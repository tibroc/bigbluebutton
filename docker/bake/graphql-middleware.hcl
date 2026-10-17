target "graphql-middleware" {
    inherits = ["docker-metadata-action", "_entrypoint-lib"]
    context = "./bbb-graphql-middleware"
    contexts = {
        bbb-yq-go = "./build/packages-template/bbb-yq-go"
    }
}
