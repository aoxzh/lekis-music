package dev.lekis.lekis

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * 音源凭据的 Android Keystore 加密（SRC-15）。
 *
 * 密钥只存在于 Android Keystore 里，Rust 通过 JNI 调这里，永远拿不到密钥本身。
 * 返回值是 `[IV 长度][IV][GCM 密文 + tag]`；调用方只把它 base64 后写进
 * 应用私有目录的 credentials.json。
 */
object CredentialCipher {
    private const val KEY_ALIAS = "lekis.credentials.v1"
    private const val TRANSFORMATION = "AES/GCM/NoPadding"
    private const val TAG_BITS = 128
    private const val MAX_IV_BYTES = 16

    @JvmStatic
    fun encrypt(plain: ByteArray): ByteArray {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, secretKey())
        val sealed = cipher.doFinal(plain)
        val iv = cipher.iv
        require(iv.size <= MAX_IV_BYTES) { "unexpected GCM IV size" }
        return ByteArray(1 + iv.size + sealed.size).also {
            it[0] = iv.size.toByte()
            iv.copyInto(it, 1)
            sealed.copyInto(it, 1 + iv.size)
        }
    }

    @JvmStatic
    fun decrypt(payload: ByteArray): ByteArray {
        require(payload.isNotEmpty()) { "empty credential payload" }
        val ivSize = payload[0].toInt() and 0xFF
        require(ivSize in 1..MAX_IV_BYTES && payload.size > 1 + ivSize) {
            "bad credential payload"
        }
        val iv = payload.copyOfRange(1, 1 + ivSize)
        val sealed = payload.copyOfRange(1 + ivSize, payload.size)
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, secretKey(), GCMParameterSpec(TAG_BITS, iv))
        return cipher.doFinal(sealed)
    }

    private fun keyStore(): KeyStore = KeyStore.getInstance("AndroidKeyStore").apply {
        load(null)
    }

    private fun secretKey(): SecretKey {
        val store = keyStore()
        (store.getEntry(KEY_ALIAS, null) as? KeyStore.SecretKeyEntry)?.let {
            return it.secretKey
        }
        val generator = KeyGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_AES,
            "AndroidKeyStore",
        )
        generator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build(),
        )
        return generator.generateKey()
    }
}
