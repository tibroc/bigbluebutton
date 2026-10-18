target "_webhooks-tags" {
    tags = bbb_image_tags("webhooks")
}

target "webhooks" {
    inherits = ["_webhooks-tags", "docker-metadata-action", "_entrypoint-lib"]
    # amd64 only: upstream's yq checksum file (build/packages-template/bbb-yq-go) covers amd64 only
    # (docker/webhooks/Dockerfile, TARGETARCH check).
    platforms = ["linux/amd64"]
    context = "./docker/webhooks"
    contexts = {
        bbb-yq-go = "./build/packages-template/bbb-yq-go"
    }
}
