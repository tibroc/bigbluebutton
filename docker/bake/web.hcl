target "web" {
    inherits = ["docker-metadata-action"]
    context = "./bigbluebutton-web"
    contexts = {
        java-base = "target:_java-base"
        bbb-common-web = "target:bbb-common-web"
        slides = "./bigbluebutton-config/slides"
    }
}
