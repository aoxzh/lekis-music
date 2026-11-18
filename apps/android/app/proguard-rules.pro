# UniFFI / JNA：生成的绑定通过反射访问 JNA 结构体和回调，不能混淆。
-keep class com.sun.jna.** { *; }
-keep class * implements com.sun.jna.** { *; }
-keep class uniffi.** { *; }
-dontwarn java.awt.**
