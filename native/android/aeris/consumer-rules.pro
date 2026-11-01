# 业务只显式导出带注解的方法；R8 必须保留其签名和运行时注解。
-keepattributes RuntimeVisibleAnnotations
-keepclassmembers class * {
    @com.aeris.sdk.BridgeMethod <methods>;
}

# Keep the runtime annotation definition for explicit exported methods.
-keep @interface com.aeris.sdk.BridgeMethod
