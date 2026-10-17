target "bbb-common-web" {
    context = "./bbb-common-web"
    contexts = {
        java-base = "target:_java-base"
        bbb-common-message = "target:bbb-common-message"
    }
}
