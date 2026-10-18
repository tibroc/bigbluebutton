# Build stage of the nginx image (docker/bake/nginx.hcl): the static html5 client, not a service.
# akka-apps and bbb-web take its settings.yml (docker/bake/apps-akka.hcl, web.hcl), so all
# three images carry the same build identifier.

# Client build identifier (html5ClientBuild in settings.yml, the ?v= cache buster of index.html
# and fonts.css), as upstream's package build passes it to build/packages-template/bbb-html5/
# build.sh: the commit date, `git log -1 --format=%cd --date=format:%Y%m%dT%H%M%S`
# (build/setup.sh). CI sets it. Empty: build.sh's fallback, the numeric BUILD, which is 0 here;
# the golden test builds use that. A build that is deployed should set it, otherwise browsers
# keep the cached client across upgrades (docker/README.md, "Building").
variable "COMMIT_DATE" {
    default = ""
}

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
    args = {
        COMMIT_DATE = COMMIT_DATE
    }
}
