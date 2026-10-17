target "nginx" {
      inherits = ["docker-metadata-action"]
      dockerfile = "./docker/nginx/Dockerfile"
      context = "."
}
