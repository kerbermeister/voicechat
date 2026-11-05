val nativeWebRtcRepository = providers.exec {
    workingDir(rootDir.resolve("../../.."))
    commandLine("python3", "infra/prepare_android_webrtc.py")
}.standardOutput.asText.get().trim()

allprojects {
    configurations.configureEach {
        resolutionStrategy.force("io.github.webrtc-sdk:android:150.7871.04-vc3")
    }
    repositories {
        maven {
            url = uri(nativeWebRtcRepository)
            content { includeModule("io.github.webrtc-sdk", "android") }
        }
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory = rootProject.layout.buildDirectory.dir("../../build").get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
