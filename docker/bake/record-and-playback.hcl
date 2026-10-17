target "record-and-playback" {
    inherits = ["docker-metadata-action"]
    context = "./record-and-playback"
    contexts = {
        bigbluebutton-config = "./bigbluebutton-config"
    }
}
