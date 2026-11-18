package dev.lekis.core.bridge

import android.content.Context
import uniffi.lekis_ffi.CredentialStore

/**
 * 凭据存储（SRC-15）。由 Rust 核心通过 UniFFI 回调接口调用（可能在任意线程上）。
 *
 * TODO(SRC-15)：**原型实现，不能发布。** 正式实现要用 Android Keystore 生成的密钥加密后再存
 * （例如 DataStore + Tink），并且备份规则里排除这个文件。
 */
internal class AndroidCredentialStore(context: Context) : CredentialStore {
    private val prefs = context.getSharedPreferences("lekis_credentials_UNSAFE_PROTOTYPE", Context.MODE_PRIVATE)

    override fun get(key: String): String? = prefs.getString(key, null)

    override fun set(key: String, secret: String): Boolean = prefs.edit().putString(key, secret).commit()

    override fun delete(key: String): Boolean = prefs.edit().remove(key).commit()
}
