# Aeris Android 0.26.0-preview.1

通用Android桥接实现，Core包名com.aeris.sdk，平台通道按容器隔离。minSdk24，JDK17；源码构建基线AGP9.2.1/Gradle9.4.1/compileSdk37。

Maven仓库为`https://raw.githubusercontent.com/zhangguozhong/aeris-maven/0.26.0-preview.1`，选择所需平台模块；已有唯一Core源码模块时不要再打包一份Maven Core。RN Codegen使用宿主显式提供的node_modules；Flutter正常构建由Flutter工具提供embedding。Unity通道实现只由UnityLibrary提供。

[安装与宿主绑定说明](https://github.com/zhangguozhong/aeris-sdk/tree/0.26.0-preview.1/README.md)。MIT。
