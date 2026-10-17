target "shared-notes" {
    inherits = ["docker-metadata-action", "_entrypoint-lib"]
    context = "./bbb-shared-notes-server"
    contexts = {
        bbb-yq-go = "./build/packages-template/bbb-yq-go"
    }
}
