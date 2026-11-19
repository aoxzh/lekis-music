# Rust 通过 JNI 按类名查找 CredentialCipher，不能被 R8 改名或裁掉。
-keep class dev.lekis.lekis.CredentialCipher { *; }

# MainActivity 里的 external fun initRustAndroidContext 依赖固定 JNI 符号名。
-keep class dev.lekis.lekis.MainActivity { *; }
