target "_certbot-tags" {
    tags = bbb_image_tags("certbot")
}

target "certbot" {
    inherits = ["_certbot-tags", "docker-metadata-action", "_entrypoint-lib"]
    context = "./docker/certbot"
}
