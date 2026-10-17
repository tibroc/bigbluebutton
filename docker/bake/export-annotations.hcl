target "_export-annotations-tags" {
      tags = bbb_image_tags("export-annotations")
}

target "export-annotations" {
      inherits = ["_export-annotations-tags", "docker-metadata-action"]
      context = "./bbb-export-annotations"
}
