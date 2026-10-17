target "nginx" {
    inherits = ["docker-metadata-action", "_entrypoint-lib"]
    context = "./docker/nginx"
    contexts = {
        html5-client = "target:html5-client"
        packages = "./build/packages-template"
        bigbluebutton-web = "./bigbluebutton-web"
        learning-dashboard = "./bbb-learning-dashboard"
        rap-presentation = "./record-and-playback/presentation/scripts"
        bigbluebutton-config = "./bigbluebutton-config"
    }
}
