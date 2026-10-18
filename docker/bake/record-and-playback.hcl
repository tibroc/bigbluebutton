target "_record-and-playback-tags" {
    tags = bbb_image_tags("record-and-playback")
}

target "record-and-playback" {
    inherits = ["_record-and-playback-tags", "docker-metadata-action"]
    context = "./record-and-playback"
    contexts = {
        bigbluebutton-config = "./bigbluebutton-config"
    }
}
