target "apps-akka" {
    inherits = ["docker-metadata-action"]
    context = "./akka-bbb-apps"
    contexts = {
        java-base = "target:_java-base"
        bbb-common-message = "target:bbb-common-message"
        html5-config = "./bigbluebutton-html5/private/config"
    }
}
