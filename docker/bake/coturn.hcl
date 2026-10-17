target "coturn" {
    inherits = ["docker-metadata-action", "_entrypoint-lib"]
    context  = "./docker/coturn"
}
