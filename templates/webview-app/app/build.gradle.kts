plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "__PKG__"
    compileSdk = 36

    defaultConfig {
        applicationId = "__PKG__"
        minSdk = 24

        // 35+ 会强制 edge-to-edge，WebView 内容顶到状态栏下面，必须自己做 inset 处理。
        // 纯套壳应用留在 34 最省事。
        targetSdk = 34

        versionCode = 1
        versionName = "1.0.0"
        resourceConfigurations += listOf("zh", "en")
    }

    buildTypes {
        release {
            isMinifyEnabled = false      // WebView + JS 桥接最怕 R8 裁掉 @JavascriptInterface，先关
            isShrinkResources = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
        debug {
            applicationIdSuffix = ".debug"
            versionNameSuffix = "-debug"
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    buildFeatures {
        buildConfig = true
    }

    // 网页资源已经被压缩过（png/webp/woff2），APK 里再压收益接近 0。
    androidResources {
        noCompress += listOf("woff2", "webp", "png", "jpg", "mp3", "ogg", "mp4")
    }

    lint {
        disable += "ExpiredTargetSdkVersion"
        disable += "OldTargetApi"
        abortOnError = false
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.15.0")
    testImplementation("junit:junit:4.13.2")
}
