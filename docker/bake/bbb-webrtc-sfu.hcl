target "bbb-webrtc-sfu" {
    inherits = ["docker-metadata-action", "_entrypoint-lib"]
    context = "./docker/bbb-webrtc-sfu"
    contexts = {
        bbb-yq-go = "./build/packages-template/bbb-yq-go"
    }
}
