plugins { id("com.android.library") }

group = "com.aeris.sdk"
version = "0.26.0-preview.2"

android {
    namespace = "com.aeris.sdk.flutter"
    compileSdk = 37
    defaultConfig { minSdk = 24; consumerProguardFiles("consumer-rules.pro") }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
dependencies {
    api("com.aeris.sdk:aeris:0.26.0-preview.1")
    testImplementation("junit:junit:4.13.2")
}
// 正常 Flutter 构建自动提供 embedding；独立 AGP 验收可显式注入真实官方 JAR。
// 仅参与编译，不下载 Flutter SDK，也不把引擎类打进插件 AAR。
val explicitEmbedding = providers.gradleProperty("aerisFlutterEmbeddingJar")
val flutterSdk = providers.gradleProperty("aerisFlutterSdk").orElse(providers.environmentVariable("FLUTTER_ROOT"))
val embedding = if (explicitEmbedding.isPresent) {
    file(explicitEmbedding.get()).also {
        check(it.isFile && it.length() > 0L) { "aerisFlutterEmbeddingJar 必须指向存在且非空的真实 Flutter embedding JAR" }
    }
} else if (flutterSdk.isPresent) {
    listOf("android-arm64", "android-x64", "android")
        .map { file("${flutterSdk.get()}/bin/cache/artifacts/engine/$it/flutter.jar") }
        .firstOrNull { it.isFile && it.length() > 0L }
} else null
if (embedding != null) dependencies { compileOnly(files(embedding)) }

// 仓库内可选本地制品生成；常规 Flutter 插件接入不需要此脚本。
val publishingConvention = file("../../../native/android/aeris-publishing.gradle")
if (publishingConvention.isFile) apply(from = publishingConvention)
