package dev.lekis.lekis

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioMixerAttributes
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject

/**
 * USB DAC 直出（PLY-05）的 Java 侧：Rust 核心通过 JNI 调 [call]，这里只做 AudioManager 调用。
 *
 * Android 14（API 34）起有 `getSupportedMixerAttributes` / `setPreferredMixerAttributes`；
 * 设备 HAL（AIDL）声明支持 `MIXER_BEHAVIOR_BIT_PERFECT` 的格式，混音器才会原样透传样本。
 * 低版本或不支持的设备上 probe 返回空的 mixers，Rust 侧据此回退普通输出。
 */
object UsbAudioBridge {
    private const val TAG = "lekis-usb"

    private var audioManager: AudioManager? = null
    private var callbackRegistered = false

    private val mediaAttributes: AudioAttributes by lazy {
        AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).build()
    }

    private val deviceCallback = object : AudioDeviceCallback() {
        override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>) {
            if (addedDevices.any { isUsbOutput(it) }) notifyChanged()
        }

        override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>) {
            if (removedDevices.any { isUsbOutput(it) }) notifyChanged()
        }
    }

    /** MainActivity.onCreate 里调用（在 initRustAndroidContext 之后）。 */
    fun init(context: Context) {
        val am = context.applicationContext.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
            ?: return
        audioManager = am
        if (!callbackRegistered) {
            am.registerAudioDeviceCallback(deviceCallback, Handler(Looper.getMainLooper()))
            callbackRegistered = true
        }
    }

    /** Activity 结束时：清掉首选混音器属性，让系统恢复普通混音。 */
    fun release() {
        try {
            nativeRelease()
        } catch (e: Throwable) {
            Log.w(TAG, "release failed", e)
        }
    }

    private fun notifyChanged() {
        try {
            nativeUsbDevicesChanged()
        } catch (e: Throwable) {
            Log.w(TAG, "hotplug notify failed", e)
        }
    }

    private fun isUsbOutput(d: AudioDeviceInfo): Boolean =
        d.isSink && (d.type == AudioDeviceInfo.TYPE_USB_DEVICE || d.type == AudioDeviceInfo.TYPE_USB_HEADSET)

    /** Rust 唯一的入口：命令字符串进，结果字符串出。任何异常都变成 `error: ...`。 */
    @JvmStatic
    fun call(cmd: String): String = try {
        val parts = cmd.trim().split(' ')
        when (parts[0]) {
            "probe" -> probe()
            "set" -> setPreferred(
                parts[1].toInt(),
                parts[2].toInt(),
                parts[3].toInt(),
                parts[4].toInt(),
            )
            "clear" -> clearPreferred(parts[1].toInt())
            else -> "error: unknown command ${parts[0]}"
        }
    } catch (e: Throwable) {
        Log.w(TAG, "call($cmd) failed", e)
        "error: ${e.javaClass.simpleName}: ${e.message}"
    }

    private fun usbOutputs(): List<AudioDeviceInfo> {
        val am = audioManager ?: return emptyList()
        return am.getDevices(AudioManager.GET_DEVICES_OUTPUTS).filter { isUsbOutput(it) }
    }

    private fun probe(): String {
        val root = JSONObject()
        root.put("sdk", Build.VERSION.SDK_INT)
        val devices = JSONArray()
        for (d in usbOutputs()) {
            val obj = JSONObject()
            obj.put("id", d.id)
            obj.put("name", d.productName?.toString() ?: "USB audio")
            obj.put("type", d.type)
            val mixers = JSONArray()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                val am = audioManager
                if (am != null) {
                    for (m in am.getSupportedMixerAttributes(d)) {
                        val f = m.format
                        mixers.put(
                            JSONObject()
                                .put("encoding", f.encoding)
                                .put("rate", f.sampleRate)
                                .put("mask", f.channelMask)
                                .put("behavior", m.mixerBehavior),
                        )
                    }
                }
            }
            obj.put("mixers", mixers)
            devices.put(obj)
        }
        root.put("devices", devices)
        return root.toString()
    }

    private fun setPreferred(deviceId: Int, encoding: Int, rate: Int, mask: Int): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            return "error: requires Android 14"
        }
        val am = audioManager ?: return "error: no AudioManager"
        val device = usbOutputs().firstOrNull { it.id == deviceId }
            ?: return "error: device $deviceId is gone"
        val format = AudioFormat.Builder()
            .setEncoding(encoding)
            .setSampleRate(rate)
            .setChannelMask(mask)
            .build()
        val attrs = AudioMixerAttributes.Builder(format)
            .setMixerBehavior(AudioMixerAttributes.MIXER_BEHAVIOR_BIT_PERFECT)
            .build()
        return if (am.setPreferredMixerAttributes(mediaAttributes, device, attrs)) {
            "ok"
        } else {
            "error: setPreferredMixerAttributes rejected $encoding/$rate/$mask"
        }
    }

    private fun clearPreferred(deviceId: Int): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) return "ok"
        val am = audioManager ?: return "error: no AudioManager"
        // 设备已经拔掉时系统会自己清掉首选属性。
        val device = usbOutputs().firstOrNull { it.id == deviceId } ?: return "ok"
        return if (am.clearPreferredMixerAttributes(mediaAttributes, device)) "ok" else "error: clear rejected"
    }

    @JvmStatic
    private external fun nativeUsbDevicesChanged()

    @JvmStatic
    private external fun nativeRelease()
}
