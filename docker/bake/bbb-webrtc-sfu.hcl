target "_bbb-webrtc-sfu-tags" {
    tags = bbb_image_tags("webrtc-sfu")
}

target "bbb-webrtc-sfu" {
    inherits = ["_bbb-webrtc-sfu-tags", "docker-metadata-action", "_entrypoint-lib"]
    context = "./docker/bbb-webrtc-sfu"
    contexts = {
        bbb-yq-go = "./build/packages-template/bbb-yq-go"
    }
}
