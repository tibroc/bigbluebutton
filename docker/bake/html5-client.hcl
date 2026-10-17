target "html5-client" {
    inherits = ["docker-metadata-action"]
    context = "./bigbluebutton-html5"
    contexts = {
        client-build = "./build/packages-template/bbb-html5"
    }
}
