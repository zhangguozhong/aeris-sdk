plugins { id("com.android.library") }

group = "com.aeris.sdk"
version = "0.26.0-preview.1"
android {
    namespace = "com.aeris.sdk.web"
    compileSdk = 37
    defaultConfig { minSdk = 24; consumerProguardFiles("consumer-rules.pro") }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
dependencies {
    api(if (rootProject.findProject(":aeris") != null) project(":aeris") else "com.aeris.sdk:aeris:0.26.0-preview.1")
    implementation("androidx.webkit:webkit:1.12.1")
    testImplementation("junit:junit:4.13.2")
}

apply(from = "../aeris-publishing.gradle")
