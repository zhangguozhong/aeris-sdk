plugins { id("com.android.library") }

android {
    namespace = "com.aeris.sdk.reactnative"
    compileSdk = 37
    defaultConfig { minSdk = 24; consumerProguardFiles("consumer-rules.pro") }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

// 优先复用宿主的唯一 Core；Maven 路径仅在宿主配置了对应固定版本仓库时启用。
group = "com.aeris.sdk"
version = "0.26.0-preview.1"
val reactNativeVersion = "0.87.0"
dependencies {
    api(if (rootProject.findProject(":aeris") != null) project(":aeris") else "com.aeris.sdk:aeris:0.26.0-preview.1")
    implementation("com.facebook.react:react-android:$reactNativeVersion")
    testImplementation("junit:junit:4.13.2")
}

val nodeModules = providers.gradleProperty("aerisNodeModulesDir").orElse(providers.provider {
    (rootProject.findProperty("aerisNodeModulesDir") ?: rootProject.findProperty("urnNodeModules"))?.toString()
        ?: rootProject.layout.projectDirectory.dir("../../tooling/android-bootstrap/node_modules").asFile.absolutePath
})
val generateCodegenArtifactsFromSchema by tasks.registering(Exec::class) {
    val generated = layout.buildDirectory.dir("generated/source/codegen")
    inputs.file("../src/specs/NativeUnifiedBridge.ts")
    inputs.file("../scripts/android-codegen.cjs")
    outputs.dir(generated)
    commandLine("node", file("../scripts/android-codegen.cjs"), nodeModules.get(), generated.get().asFile)
}
tasks.named("preBuild").configure { dependsOn(generateCodegenArtifactsFromSchema) }

// 使用 AGP 9 公共 Variant API，避免旧 sourceSets Kotlin DSL 的类型转换。
androidComponents {
    onVariants { variant ->
        variant.sources.java?.addStaticSourceDirectory(
            layout.buildDirectory.dir("generated/source/codegen/java").get().asFile.absolutePath,
        )
    }
}

apply(from = "aeris-publishing.gradle")
