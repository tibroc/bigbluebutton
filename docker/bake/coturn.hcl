target "_coturn-tags" {
    tags = bbb_image_tags("coturn")
}

target "coturn" {
    inherits = ["_coturn-tags", "docker-metadata-action", "_entrypoint-lib"]
    context  = "./docker/coturn"
}
