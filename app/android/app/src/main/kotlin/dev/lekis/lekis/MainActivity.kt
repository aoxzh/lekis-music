package dev.lekis.lekis

import android.content.Context
import android.os.Bundle
import com.ryanheise.audioservice.AudioServiceActivity

// audio_service 要求 Activity 继承 AudioServiceActivity，Flutter 引擎才能和后台媒体服务共用。
class MainActivity : AudioServiceActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        // Rust 核心的音频输出（cpal → AAudio）需要 JavaVM 和 Context，必须在 Dart 调用核心之前登记。
        System.loadLibrary("lekis_bridge")
        initRustAndroidContext(applicationContext)
        super.onCreate(savedInstanceState)
    }

    companion object {
        @JvmStatic
        external fun initRustAndroidContext(context: Context)
    }
}
