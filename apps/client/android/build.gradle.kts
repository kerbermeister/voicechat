import groovy.json.JsonSlurper

val nativeSdk = JsonSlurper().parseText(
    providers.exec {
        commandLine("python3", file("../../../infra/prepare_android_webrtc.py"))
    }.standardOutput.asText.get()
) as Map<*, *>

allprojects {
    configurations.configureEach {
        resolutionStrategy.force("io.github.webrtc-sdk:android:${nativeSdk["version"]}")
    }
    repositories {
        exclusiveContent {
            forRepository {
                maven { url = uri(nativeSdk["repository"] as String) }
            }
            filter { includeModule("io.github.webrtc-sdk", "android") }
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
