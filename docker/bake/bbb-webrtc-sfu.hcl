target "_bbb-webrtc-sfu-tags" {
    tags = bbb_image_tags("webrtc-sfu")
}

target "bbb-webrtc-sfu" {
    inherits = ["_bbb-webrtc-sfu-tags", "docker-metadata-action", "_entrypoint-lib"]
    # amd64 only: upstream's yq checksum file (build/packages-template/bbb-yq-go) covers amd64 only
    # (docker/bbb-webrtc-sfu/Dockerfile, TARGETARCH check).
    platforms = ["linux/amd64"]
    context = "./docker/bbb-webrtc-sfu"
    contexts = {
        bbb-yq-go = "./build/packages-template/bbb-yq-go"
    }
}
