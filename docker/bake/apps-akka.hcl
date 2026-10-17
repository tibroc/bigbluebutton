# akka-apps: built on bbb-common-message (build stage) and the Java base (runtime, which
# already contains the entrypoint helper). html5-config: the HTML5 client settings.yml, which
# akka-apps reads and hands to clients.
target "apps-akka" {
    inherits = ["docker-metadata-action"]
    context = "./akka-bbb-apps"
    contexts = {
        java-base = "target:_java-base"
        bbb-common-message = "target:bbb-common-message"
        html5-config = "./bigbluebutton-html5/private/config"
    }
}
