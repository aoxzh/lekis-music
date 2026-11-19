//! Android：把 JavaVM 和应用 Context 登记给 `ndk-context`。
//!
//! cpal 在 Android 上通过 `ndk_context::android_context()` 拿 JavaVM/Context 来打开 AAudio，
//! 没登记就会 panic（"android context was not initialized"），表现为完全放不出声。
//! Flutter 应用不是 NativeActivity，没人替我们做这件事，所以由 MainActivity 在启动时调用一次。

use std::ffi::c_void;
use std::sync::Once;

use jni_sys::{jclass, jobject, JNIEnv, JavaVM, JNI_OK};

static INIT: Once = Once::new();

/// Kotlin: `external fun initRustAndroidContext(context: Context)`（在 `dev.lekis.lekis.MainActivity` 的 companion 里）。
///
/// # Safety
/// 只能由 JVM 通过 JNI 调用；`env` 和 `context` 必须是 JVM 传进来的有效指针。
#[no_mangle]
pub unsafe extern "system" fn Java_dev_lekis_lekis_MainActivity_initRustAndroidContext(
    env: *mut JNIEnv,
    _class: jclass,
    context: jobject,
) {
    INIT.call_once(|| {
        // SAFETY: env/context 由 JVM 传入，在本次调用期间有效。
        unsafe {
            if env.is_null() || (*env).is_null() {
                return;
            }
            let fns = &**env;
            let mut vm: *mut JavaVM = std::ptr::null_mut();
            let (Some(get_vm), Some(new_global)) = (fns.GetJavaVM, fns.NewGlobalRef) else {
                return;
            };
            if get_vm(env, &mut vm) != JNI_OK || vm.is_null() {
                return;
            }
            // 全局引用，进程结束前不释放：ndk-context 要求 Context 一直有效。
            let global = new_global(env, context);
            if global.is_null() {
                return;
            }
            ndk_context::initialize_android_context(vm as *mut c_void, global as *mut c_void);
        }
    });
}
