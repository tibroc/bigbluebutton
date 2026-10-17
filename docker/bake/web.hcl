target "web" {
    inherits = ["docker-metadata-action"]
    context = "./bigbluebutton-web"
    contexts = {
        java-base = "target:_java-base"
        bbb-common-web = "target:bbb-common-web"
        bbb-web-package = "./build/packages-template/bbb-web"
        slides = "./bigbluebutton-config/slides"
        html5-config = "./bigbluebutton-html5/private/config"
    }
}
