plugins { id("com.android.library") }

group = "com.aeris.sdk"
version = "0.26.0-preview.2"

android {
    namespace = "com.aeris.sdk.unity"
    compileSdk = 37
    defaultConfig { minSdk = 24; consumerProguardFiles("consumer-rules.pro") }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
}

dependencies {
    api(if (rootProject.findProject(":aeris") != null) project(":aeris") else "com.aeris.sdk:aeris:0.26.0-preview.2")
    // UnityLibrary 拥有 Java 插件实现，宿主 AAR 禁止再打包一份。
    compileOnly(if (rootProject.findProject(":aeris-unity-channel") != null) project(":aeris-unity-channel") else "com.aeris.sdk:aeris-unity-channel:0.26.0-preview.2")
    testImplementation(if (rootProject.findProject(":aeris-unity-channel") != null) project(":aeris-unity-channel") else "com.aeris.sdk:aeris-unity-channel:0.26.0-preview.2")
}

apply(from = "../aeris-publishing.gradle")
