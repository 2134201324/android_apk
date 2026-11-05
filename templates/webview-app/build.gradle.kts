// 根构建脚本：只声明插件版本，不 apply。
// 插件版本与 Gradle 8.14.3、JDK 17+ 已实测配套，不要单独升级某一个。
plugins {
    id("com.android.application") version "8.13.0" apply false
    id("org.jetbrains.kotlin.android") version "2.0.21" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.0.21" apply false
}
