# R8 保活规则（isMinifyEnabled=true 时才生效）
#
# 常见必须保活的：
# - 反射加载的类（Class.forName("...")）
# - kotlinx.serialization 的 @Serializable 模型（有官方规则，通常自动带）
# - 通过 JSON 字段名反序列化的 DTO
# - JNI 调用的类与方法
#
# 示例：
# -keep class __PKG__.data.model.** { *; }
# -keepclassmembers class * {
#     @androidx.annotation.Keep <methods>;
# }

# 保留行号，崩溃栈才可读（release 包崩溃时最有用的信息）
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile
