target "haproxy" {
    inherits = ["docker-metadata-action", "_entrypoint-lib"]
    context = "./docker/haproxy"
}
