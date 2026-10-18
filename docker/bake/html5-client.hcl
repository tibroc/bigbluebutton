# Build stage of the nginx image (docker/bake/nginx.hcl): the static html5 client, not a service.
target "_html5-client-tags" {
    tags = bbb_image_tags("html5-client")
}

target "html5-client" {
    inherits = ["_html5-client-tags", "docker-metadata-action"]
    platforms = compact(split(",", BBB_PLATFORMS))
    context = "./bigbluebutton-html5"
    contexts = {
        bbb-config = "./bigbluebutton-config"
    }
}
