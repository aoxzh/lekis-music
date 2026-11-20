//! Android：把 JavaVM 和应用 Context 登记给 `ndk-context`。
//!
//! cpal 在 Android 上通过 `ndk_context::android_context()` 拿 JavaVM/Context 来打开 AAudio，
//! 没登记就会 panic（"android context was not initialized"），表现为完全放不出声。
//! Flutter 应用不是 NativeActivity，没人替我们做这件事，所以由 MainActivity 在启动时调用一次。

use std::ffi::c_void;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Once;

use jni_sys::{jclass, jobject, JNIEnv, JavaVM, JNI_OK};

static INIT: Once = Once::new();

/// `CredentialCipher` 的全局引用。凭据加密发生在 Rust 的后台线程里，
/// 那些线程用 `FindClass` 找不到 App 自己的类，所以在 MainActivity 的
/// Java 线程里先缓存一份。
static CREDENTIAL_CIPHER_CLASS: AtomicUsize = AtomicUsize::new(0);

/// 给 `credentials.rs` 用的全局类引用（未初始化时为 `None`）。
pub(crate) fn credential_cipher_class() -> Option<jclass> {
    let raw = CREDENTIAL_CIPHER_CLASS.load(Ordering::Relaxed);
    (raw != 0).then_some(raw as jclass)
}

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
            cache_credential_cipher_class(env, fns);
        }
    });
}

/// 在 Java 线程上缓存 `dev.lekis.lekis.CredentialCipher` 的全局引用。
///
/// # Safety
/// `env` 必须是当前 Java 线程的合法 JNIEnv，`fns` 必须来自同一个 JNIEnv。
unsafe fn cache_credential_cipher_class(env: *mut JNIEnv, fns: &jni_sys::JNINativeInterface_) {
    let (
        Some(find_class),
        Some(new_global),
        Some(delete_local_ref),
        Some(exception_check),
        Some(exception_clear),
    ) = (
        fns.FindClass,
        fns.NewGlobalRef,
        fns.DeleteLocalRef,
        fns.ExceptionCheck,
        fns.ExceptionClear,
    )
    else {
        return;
    };
    // SAFETY: 类名字面量以 NUL 结尾；env 在本次 JNI 调用期间有效。
    let local = unsafe { find_class(env, b"dev/lekis/lekis/CredentialCipher\0".as_ptr().cast()) };
    if local.is_null() {
        // 查找失败会挂起一个 NoClassDefFoundError，必须清掉再返回。
        if unsafe { exception_check(env) } != 0 {
            unsafe { exception_clear(env) };
        }
        return;
    }
    // SAFETY: local 是 FindClass 返回的局部引用。
    let global = unsafe { new_global(env, local) };
    // SAFETY: local 用完就可以释放。
    unsafe { delete_local_ref(env, local) };
    if !global.is_null() {
        CREDENTIAL_CIPHER_CLASS.store(global as usize, Ordering::Relaxed);
    }
}
