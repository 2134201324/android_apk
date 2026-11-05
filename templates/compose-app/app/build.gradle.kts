plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "__PKG__"
    compileSdk = 36

    defaultConfig {
        applicationId = "__PKG__"
        minSdk = 24

        // targetSdk 说明（改之前必读 references/pitfalls.md 第 1 条）：
        // · 34 = 不开 edge-to-edge 强制、不需要处理新分区存储行为，最稳；
        // · 35+ = Android 15 起强制 edge-to-edge，Compose 内容会顶到状态栏下面，
        //   必须自己加 WindowInsets 处理，否则首屏就是「标题被状态栏压住」；
        // · ≤28 = 只有「要在应用私有目录里 exec 二进制」（内置终端/自带运行时）
        //   才需要，普通 UI 应用不要降。
        targetSdk = 34

        versionCode = 1
        versionName = "1.0.0"

        // 只保留需要的语言，能把 resources.arsc 压小几百 KB。
        resourceConfigurations += listOf("zh", "en")
    }

    buildTypes {
        release {
            // 首次构建建议保持 false：R8 一旦裁掉反射用到的类，表现为
            // 「debug 正常、release 一开就闪退」，排查成本很高。
            // 包体确实需要压缩时改为 true，并把反射入口写进 proguard-rules.pro。
            isMinifyEnabled = false
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
        compose = true
        buildConfig = true
    }

    // 已经 zipalign 过的 so / 已压缩资源再压一次只会让安装变慢。
    packaging {
        resources.excludes += setOf(
            "/META-INF/{AL2.0,LGPL2.1}",
            "META-INF/DEPENDENCIES",
            "META-INF/LICENSE*",
            "META-INF/NOTICE*"
        )
    }

    // assets 里已经是压缩格式的文件不要重复压缩（APK 里再压一遍毫无收益，
    // 还会让运行时读取变慢；.so 不压缩还能让安装器直接 mmap）。
    androidResources {
        noCompress += listOf("zip", "mp3", "mp4", "ogg", "webp", "so")
    }

    lint {
        // 这两项在 targetSdk 偏保守时会直接判红，阻断 release 构建。
        disable += "ExpiredTargetSdkVersion"
        disable += "OldTargetApi"
        abortOnError = false
    }

    testOptions {
        unitTests.isReturnDefaultValues = true
    }
}

dependencies {
    implementation(platform("androidx.compose:compose-bom:2024.12.01"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-graphics")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.material3:material3")

    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.7")

    debugImplementation("androidx.compose.ui:ui-tooling")
    testImplementation("junit:junit:4.13.2")
}
