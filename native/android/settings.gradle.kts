pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        providers.gradleProperty("aerisMavenRepository").orNull?.let { candidateRepository ->
            maven { url = uri(candidateRepository) }
        }
        google()
        mavenCentral()
    }
}

rootProject.name = "aeris-android"
include(":aeris")

include(":aeris-react-native")
project(":aeris-react-native").projectDir = file("../../packages/react-native/android")

include(":aeris-web")
include(":aeris-flutter")
project(":aeris-flutter").projectDir = file("../../packages/flutter/android")
include(":aeris-unity")
include(":aeris-unity-channel")
project(":aeris-unity-channel").projectDir = file("aeris-unity/channel")
