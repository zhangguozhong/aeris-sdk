plugins { `java-library`; `maven-publish` }

group = "com.aeris.sdk"
version = "0.26.0-preview.2"

java { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17; withSourcesJar() }
// 仅用于编译宿主契约；最终 APK 中的唯一类定义由 UnityLibrary 导出提供。
sourceSets { main { java.srcDir("../../../../packages/unity/Plugins/Android") } }


publishing {
    publications { create<MavenPublication>("release") { from(components["java"]) } }
    repositories {
        maven {
            name = "aerisStaging"
            url = uri(providers.gradleProperty("aerisMavenStagingDir").getOrElse(rootProject.layout.buildDirectory.dir("aeris-maven").get().asFile.path))
        }
    }
}
