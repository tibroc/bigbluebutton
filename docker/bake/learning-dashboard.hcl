# Build stage of the nginx image (docker/bake/nginx.hcl): the static learning dashboard, not a
# service.
target "_learning-dashboard-tags" {
      tags = bbb_image_tags("learning-dashboard")
}

target "learning-dashboard" {
      inherits = ["_learning-dashboard-tags", "docker-metadata-action"]
      platforms = compact(split(",", BBB_PLATFORMS))
      context = "./bbb-learning-dashboard"
}
