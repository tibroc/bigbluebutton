target "livekit" {
    inherits = ["docker-metadata-action", "_entrypoint-lib"]
    context = "./docker/livekit"
    contexts = {
        bbb-livekit = "./build/packages-template/bbb-livekit"
        bbb-yq-go = "./build/packages-template/bbb-yq-go"
    }
}
