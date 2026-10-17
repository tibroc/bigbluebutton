# Build stage of the nginx image (docker/bake/nginx.hcl): the static html5 client, not a service.
target "html5-client" {
    inherits = ["docker-metadata-action"]
    context = "./bigbluebutton-html5"
    contexts = {
        bbb-config = "./bigbluebutton-config"
    }
}
