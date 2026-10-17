target "graphql-server" {
    inherits = ["docker-metadata-action", "_entrypoint-lib"]
    context = "./bbb-graphql-server"
    contexts = {
        graphql-server-pkg = "./build/packages-template/bbb-graphql-server"
        bbb-yq-go = "./build/packages-template/bbb-yq-go"
    }
}
