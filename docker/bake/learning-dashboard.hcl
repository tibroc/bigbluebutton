target "_learning-dashboard-tags" {
      tags = bbb_image_tags("learning-dashboard")
}

target "learning-dashboard" {
      inherits = ["_learning-dashboard-tags", "docker-metadata-action"]
      context = "./bbb-learning-dashboard"
}
