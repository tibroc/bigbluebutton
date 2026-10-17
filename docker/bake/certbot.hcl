target "certbot" {
    inherits = ["docker-metadata-action", "_entrypoint-lib"]
    context = "./docker/certbot"
}
