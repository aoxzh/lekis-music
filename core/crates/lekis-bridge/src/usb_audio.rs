//! Android USB DAC 直出的平台层（PLY-05）。
//!
//! `AudioManager` 的混音器属性 API 只有 Java 接口，这里通过 JNI 调 `UsbAudioBridge.kt`：
//! 所有方法都收发字符串（`call(String): String`），Rust 侧只需要一个 JNI 签名。
//!
//! | 命令 | 返回 |
//! |---|---|
//! | `probe` | JSON：`{"sdk":36,"devices":[{"id":..,"name":..,"mixers":[{"encoding":..,"rate":..,"mask":..,"behavior":..}]}]}` |
//! | `set <id> <encoding> <rate> <mask>` | `ok` 或 `error: ...` |
//! | `clear <id>` | `ok` 或 `error: ...` |

use lekis_playback::output::usb_direct;
use lekis_playback::OutputMode;

use crate::api::error::CoreError;
use crate::internal::{core, CORE};

/// 设置项：USB 直出开关（`true` / `false`）。本机设置，不同步。
pub(crate) const USB_BIT_PERFECT_SETTING: &str = "playback.usb_bit_perfect";

/// 打开 / 关闭 USB 直出：同步引擎的输出模式。非 Android 上什么也不做。
pub(crate) fn apply(enabled: bool) -> Result<(), CoreError> {
    if !cfg!(target_os = "android") {
        return Ok(());
    }
    usb_direct::set_usb_direct_enabled(enabled);
    let mode = if enabled {
        OutputMode::Exclusive
    } else {
        OutputMode::Shared
    };
    Ok(core().set_output_mode(mode)?)
}

/// USB 设备插拔后：开关打开时让引擎重建输出流（按新设备重新协商；拔掉时回到普通输出）。
#[cfg_attr(not(target_os = "android"), allow(dead_code))]
pub(crate) fn on_devices_changed() {
    usb_direct::usb_devices_changed();
    if !usb_direct::usb_direct_enabled() || CORE.get().is_none() {
        return;
    }
    // 引擎只在模式变化时重建流：先切共享再切回独占（命令按顺序排队，不阻塞调用线程）。
    let _ = core().set_output_mode(OutputMode::Shared);
    let _ = core().set_output_mode(OutputMode::Exclusive);
}

/// 核心初始化后：登记平台能力，并恢复上次保存的开关（在后台线程里读设置，不拖慢启动）。
#[cfg(target_os = "android")]
pub(crate) fn init_after_core() {
    usb_direct::register_usb_platform(std::sync::Arc::new(jni_platform::JniUsbPlatform));
    let _ = std::thread::Builder::new()
        .name("lekis-usb-restore".into())
        .spawn(|| {
            let saved = block_on(core().get_setting(USB_BIT_PERFECT_SETTING.to_string()));
            if matches!(saved, Ok(Some(ref v)) if v == "true") {
                tracing::info!(target: "bridge::usb", "restoring USB bit-perfect output");
                let _ = apply(true);
            }
        });
}

/// 极简 block_on：核心的异步函数只是在核心运行时上 spawn 再等 JoinHandle，
/// 在普通线程上停车等待就够了，不需要再起一个运行时。
#[cfg(target_os = "android")]
fn block_on<F: std::future::Future>(fut: F) -> F::Output {
    use std::sync::Arc;
    use std::task::{Context, Poll, Wake, Waker};

    struct Unpark(std::thread::Thread);
    impl Wake for Unpark {
        fn wake(self: Arc<Self>) {
            self.0.unpark();
        }
    }
    let waker = Waker::from(Arc::new(Unpark(std::thread::current())));
    let mut cx = Context::from_waker(&waker);
    let mut fut = std::pin::pin!(fut);
    loop {
        if let Poll::Ready(v) = fut.as_mut().poll(&mut cx) {
            return v;
        }
        std::thread::park();
    }
}

/// Kotlin: `UsbAudioBridge.nativeUsbDevicesChanged()`（AudioDeviceCallback 里 USB 设备增删时调用）。
///
/// # Safety
/// 只能由 JVM 通过 JNI 调用。
#[cfg(target_os = "android")]
#[no_mangle]
pub unsafe extern "system" fn Java_dev_lekis_lekis_UsbAudioBridge_nativeUsbDevicesChanged(
    _env: *mut jni_sys::JNIEnv,
    _class: jni_sys::jclass,
) {
    // 不在 Java 主线程上做探测和引擎命令：JNI 回调里要尽快返回。
    let _ = std::thread::Builder::new()
        .name("lekis-usb-hotplug".into())
        .spawn(on_devices_changed);
}

/// Kotlin: `UsbAudioBridge.nativeRelease()`（Activity 结束时清掉首选混音器属性）。
///
/// # Safety
/// 只能由 JVM 通过 JNI 调用。
#[cfg(target_os = "android")]
#[no_mangle]
pub unsafe extern "system" fn Java_dev_lekis_lekis_UsbAudioBridge_nativeRelease(
    _env: *mut jni_sys::JNIEnv,
    _class: jni_sys::jclass,
) {
    usb_direct::usb_direct_release();
}

#[cfg(target_os = "android")]
mod jni_platform {
    use std::ffi::{c_void, CStr, CString};
    use std::ptr;

    use jni_sys::{jclass, jobject, jstring, jvalue, JNIEnv, JavaVM, JNI_EDETACHED, JNI_OK, JNI_VERSION_1_6};
    use lekis_playback::output::usb_direct::{
        MixerFormat, UsbAudioDevice, UsbAudioPlatform, UsbProbe,
    };
    use lekis_types::{ErrorCode, LekisError, Result};

    const METHOD: &[u8] = b"call\0";
    const SIGNATURE: &[u8] = b"(Ljava/lang/String;)Ljava/lang/String;\0";

    pub(super) struct JniUsbPlatform;

    #[derive(serde::Deserialize)]
    struct ProbeJson {
        sdk: i32,
        #[serde(default)]
        devices: Vec<DeviceJson>,
    }

    #[derive(serde::Deserialize)]
    struct DeviceJson {
        id: i32,
        name: String,
        #[serde(default)]
        mixers: Vec<MixerJson>,
    }

    #[derive(serde::Deserialize)]
    struct MixerJson {
        encoding: i32,
        rate: u32,
        mask: i32,
        behavior: i32,
    }

    impl UsbAudioPlatform for JniUsbPlatform {
        fn probe(&self) -> Result<UsbProbe> {
            let raw = call("probe")?;
            tracing::info!(target: "bridge::usb", probe = %raw, "USB audio probe");
            let parsed: ProbeJson = serde_json::from_str(&raw)
                .map_err(|e| LekisError::internal(format!("bad USB probe JSON: {e}")))?;
            Ok(UsbProbe {
                sdk_int: parsed.sdk,
                devices: parsed
                    .devices
                    .into_iter()
                    .map(|d| UsbAudioDevice {
                        id: d.id,
                        name: d.name,
                        mixer_formats: d
                            .mixers
                            .into_iter()
                            .map(|m| MixerFormat {
                                encoding: m.encoding,
                                sample_rate: m.rate,
                                channel_mask: m.mask,
                                behavior: m.behavior,
                            })
                            .collect(),
                    })
                    .collect(),
            })
        }

        fn set_preferred(&self, device_id: i32, format: &MixerFormat) -> Result<()> {
            let reply = call(&format!(
                "set {device_id} {} {} {}",
                format.encoding, format.sample_rate, format.channel_mask
            ))?;
            tracing::info!(target: "bridge::usb", device_id, ?format, %reply, "setPreferredMixerAttributes");
            check(reply)
        }

        fn clear_preferred(&self, device_id: i32) -> Result<()> {
            let reply = call(&format!("clear {device_id}"))?;
            tracing::info!(target: "bridge::usb", device_id, %reply, "clearPreferredMixerAttributes");
            check(reply)
        }
    }

    fn check(reply: String) -> Result<()> {
        if reply == "ok" {
            Ok(())
        } else {
            Err(LekisError::new(ErrorCode::Unsupported, reply))
        }
    }

    fn internal(message: &str) -> LekisError {
        LekisError::internal(format!("android USB audio bridge: {message}"))
    }

    /// 调 `UsbAudioBridge.call(cmd)`。任意线程可用（必要时临时附加到 JVM）。
    fn call(cmd: &str) -> Result<String> {
        let ctx = ndk_context::android_context();
        let vm = ctx.vm().cast::<JavaVM>();
        if vm.is_null() {
            return Err(internal("JavaVM is not initialized"));
        }
        let class = crate::android_context::usb_audio_bridge_class()
            .ok_or_else(|| internal("UsbAudioBridge class is not available"))?;
        let cmd = CString::new(cmd).map_err(|_| internal("command contains NUL"))?;

        // SAFETY: vm 来自 MainActivity 登记的 ndk-context，存活到进程结束。
        unsafe {
            let fns = &**vm;
            let get_env = fns.GetEnv.ok_or_else(|| internal("GetEnv unavailable"))?;
            let attach = fns
                .AttachCurrentThread
                .ok_or_else(|| internal("AttachCurrentThread unavailable"))?;
            let mut env: *mut JNIEnv = ptr::null_mut();
            let mut attached = false;
            let mut status = get_env(
                vm,
                (&mut env as *mut *mut JNIEnv).cast::<*mut c_void>(),
                JNI_VERSION_1_6,
            );
            if status == JNI_EDETACHED {
                status = attach(
                    vm,
                    (&mut env as *mut *mut JNIEnv).cast::<*mut c_void>(),
                    ptr::null_mut(),
                );
                if status != JNI_OK {
                    return Err(internal("cannot attach thread to the JVM"));
                }
                attached = true;
            } else if status != JNI_OK {
                return Err(internal("cannot get the JNI environment"));
            }
            let result = call_with_env(env, class, &cmd);
            if attached {
                if let Some(detach) = fns.DetachCurrentThread {
                    detach(vm);
                }
            }
            result
        }
    }

    /// # Safety
    /// `env` 必须是当前线程的合法 JNIEnv，`class` 是全局类引用。
    unsafe fn call_with_env(env: *mut JNIEnv, class: jclass, cmd: &CStr) -> Result<String> {
        // SAFETY: env 由调用方保证有效。
        let fns = unsafe { &**env };
        let (
            Some(new_string),
            Some(get_static_method),
            Some(call_static),
            Some(get_chars),
            Some(release_chars),
            Some(delete_local_ref),
            Some(exception_check),
            Some(exception_clear),
        ) = (
            fns.NewStringUTF,
            fns.GetStaticMethodID,
            fns.CallStaticObjectMethodA,
            fns.GetStringUTFChars,
            fns.ReleaseStringUTFChars,
            fns.DeleteLocalRef,
            fns.ExceptionCheck,
            fns.ExceptionClear,
        )
        else {
            return Err(internal("required JNI functions are unavailable"));
        };
        let clear = |env: *mut JNIEnv| -> bool {
            // SAFETY: 同一个 env。
            unsafe {
                if exception_check(env) != 0 {
                    exception_clear(env);
                    true
                } else {
                    false
                }
            }
        };

        // SAFETY: 每个 JNI 调用只使用本函数内创建的局部引用。
        unsafe {
            let method = get_static_method(env, class, METHOD.as_ptr().cast(), SIGNATURE.as_ptr().cast());
            if method.is_null() || clear(env) {
                return Err(internal("UsbAudioBridge.call is missing"));
            }
            let arg = new_string(env, cmd.as_ptr());
            if arg.is_null() || clear(env) {
                return Err(internal("cannot create the JNI string"));
            }
            let args = [jvalue { l: arg as jobject }];
            let reply: jobject = call_static(env, class, method, args.as_ptr());
            delete_local_ref(env, arg as jobject);
            if clear(env) {
                if !reply.is_null() {
                    delete_local_ref(env, reply);
                }
                return Err(internal("UsbAudioBridge.call threw"));
            }
            if reply.is_null() {
                return Err(internal("UsbAudioBridge.call returned null"));
            }
            let chars = get_chars(env, reply as jstring, ptr::null_mut());
            if chars.is_null() {
                delete_local_ref(env, reply);
                clear(env);
                return Err(internal("cannot read the reply string"));
            }
            let out = CStr::from_ptr(chars).to_string_lossy().into_owned();
            release_chars(env, reply as jstring, chars);
            delete_local_ref(env, reply);
            Ok(out)
        }
    }
}
