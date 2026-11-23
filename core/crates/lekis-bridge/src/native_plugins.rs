//! Generic Android DEX execution. Authorization belongs to the plugin host, not this JNI adapter.

use lekis_types::{ErrorCode, LekisError, Result};
use serde_json::Value;

const MAX_PAYLOAD_BYTES: usize = 8 * 1024 * 1024;

fn decode_reply(reply: &str) -> Result<Value> {
    if reply.len() > MAX_PAYLOAD_BYTES {
        return Err(LekisError::invalid("native plugin response exceeds 8 MiB"));
    }
    let envelope: Value = serde_json::from_str(reply)
        .map_err(|_| LekisError::invalid("native plugin returned invalid JSON"))?;
    match envelope.get("ok").and_then(Value::as_bool) {
        Some(true) => envelope
            .get("result")
            .cloned()
            .ok_or_else(|| LekisError::invalid("native plugin response has no result")),
        Some(false) => {
            let error = envelope
                .get("error")
                .ok_or_else(|| LekisError::invalid("native plugin response has no error"))?;
            let code = error
                .get("code")
                .and_then(Value::as_str)
                .ok_or_else(|| LekisError::invalid("native plugin error has no code"))?;
            let message = error
                .get("message")
                .and_then(Value::as_str)
                .ok_or_else(|| LekisError::invalid("native plugin error has no message"))?;
            let code = match code {
                "busy" | "rateLimited" => ErrorCode::RateLimited,
                "timeout" | "unavailable" => ErrorCode::Network,
                "signIn" => ErrorCode::Auth,
                "setup" => ErrorCode::InvalidArgument,
                other => {
                    serde_json::from_value(Value::String(other.into())).unwrap_or(ErrorCode::Plugin)
                }
            };
            Err(LekisError::new(
                code,
                message.chars().take(2048).collect::<String>(),
            ))
        }
        None => Err(LekisError::invalid(
            "native plugin response has no boolean ok field",
        )),
    }
}

#[cfg(target_os = "android")]
mod android {
    use super::*;
    use jni_sys::{
        jclass, jstring, jvalue, JNIEnv, JavaVM, JNI_EDETACHED, JNI_OK, JNI_VERSION_1_6,
    };
    use lekis_core::{NativePluginExecutor, NativePluginRequest};
    use std::ffi::c_void;
    use std::ptr;
    use std::sync::{Arc, OnceLock};

    struct AndroidNativeExecutor;

    pub(crate) fn register() -> Result<()> {
        static EXECUTOR: OnceLock<Arc<AndroidNativeExecutor>> = OnceLock::new();
        let executor = EXECUTOR
            .get_or_init(|| Arc::new(AndroidNativeExecutor))
            .clone();
        lekis_core::register_native_plugin_executor(executor)
    }

    fn jni_error(message: &str) -> LekisError {
        LekisError::new(
            ErrorCode::Plugin,
            format!("Android native plugin bridge: {message}"),
        )
    }

    impl NativePluginExecutor for AndroidNativeExecutor {
        fn call(&self, request: NativePluginRequest) -> Result<Value> {
            let payload = serde_json::to_string(&request.params)
                .map_err(|_| LekisError::invalid("cannot serialize native plugin payload"))?;
            if payload.len() > MAX_PAYLOAD_BYTES {
                return Err(LekisError::invalid("native plugin payload exceeds 8 MiB"));
            }
            let root = request
                .plugin_root
                .to_str()
                .ok_or_else(|| LekisError::invalid("native plugin path is not UTF-8"))?;
            let inputs = [
                root,
                request.spec.entry.as_str(),
                request.spec.class_name.as_str(),
                request.operation.as_str(),
                payload.as_str(),
            ];
            if inputs[..4].iter().any(|input| input.len() > 8192) {
                return Err(LekisError::invalid(
                    "native plugin request field exceeds size limit",
                ));
            }
            let class = crate::android_context::native_plugin_bridge_class()
                .ok_or_else(|| jni_error("Java helper is unavailable"))?;
            let vm = ndk_context::android_context().vm().cast::<JavaVM>();
            if vm.is_null() {
                return Err(jni_error("JavaVM is unavailable"));
            }
            // SAFETY: the JVM and global class are retained for the app process by android_context.
            unsafe {
                let functions = &**vm;
                let get_env = functions
                    .GetEnv
                    .ok_or_else(|| jni_error("GetEnv unavailable"))?;
                let attach = functions
                    .AttachCurrentThread
                    .ok_or_else(|| jni_error("AttachCurrentThread unavailable"))?;
                let mut env: *mut JNIEnv = ptr::null_mut();
                let mut status = get_env(
                    vm,
                    (&mut env as *mut *mut JNIEnv).cast::<*mut c_void>(),
                    JNI_VERSION_1_6,
                );
                let attached = status == JNI_EDETACHED;
                if attached {
                    status = attach(
                        vm,
                        (&mut env as *mut *mut JNIEnv).cast::<*mut c_void>(),
                        ptr::null_mut(),
                    );
                }
                if status != JNI_OK {
                    return Err(jni_error("cannot attach calling thread"));
                }
                let result = if env.is_null() {
                    Err(jni_error("JVM returned no JNIEnv"))
                } else {
                    call_with_env(env, class, inputs)
                };
                if attached {
                    if let Some(detach) = functions.DetachCurrentThread {
                        detach(vm);
                    }
                }
                decode_reply(&result?)
            }
        }
    }

    /// SAFETY: env is attached to this thread, and class is a process-lifetime global reference.
    unsafe fn call_with_env(env: *mut JNIEnv, class: jclass, inputs: [&str; 5]) -> Result<String> {
        let functions = unsafe { &**env };
        let (
            Some(push),
            Some(pop),
            Some(new_string),
            Some(get_method),
            Some(call),
            Some(string_length),
            Some(string_chars),
            Some(release_chars),
            Some(check),
            Some(clear),
        ) = (
            functions.PushLocalFrame,
            functions.PopLocalFrame,
            functions.NewString,
            functions.GetStaticMethodID,
            functions.CallStaticObjectMethodA,
            functions.GetStringLength,
            functions.GetStringChars,
            functions.ReleaseStringChars,
            functions.ExceptionCheck,
            functions.ExceptionClear,
        )
        else {
            return Err(jni_error("required JNI functions are unavailable"));
        };
        let exception = || unsafe {
            if check(env) != 0 {
                clear(env);
                true
            } else {
                false
            }
        };
        // Bound local references even when a Rust worker is already attached to the JVM.
        if unsafe { push(env, 8) } != JNI_OK {
            exception();
            return Err(jni_error("cannot create local reference frame"));
        }
        let result = (|| {
            let mut args = [jvalue { l: ptr::null_mut() }; 5];
            for (slot, input) in args.iter_mut().zip(inputs) {
                // NewString uses UTF-16, preserving emoji, Chinese text, and embedded NULs.
                let utf16: Vec<u16> = input.encode_utf16().collect();
                slot.l = unsafe { new_string(env, utf16.as_ptr(), utf16.len() as i32) };
                if exception() || slot.l.is_null() {
                    return Err(jni_error("cannot allocate Java string"));
                }
            }
            let method = unsafe {
                get_method(env, class, b"call\0".as_ptr().cast(),
                b"(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;\0".as_ptr().cast())
            };
            if exception() || method.is_null() {
                return Err(jni_error("Java helper method is unavailable"));
            }
            let reply = unsafe { call(env, class, method, args.as_ptr()) } as jstring;
            if exception() || reply.is_null() {
                return Err(jni_error("Java helper failed"));
            }
            let length = unsafe { string_length(env, reply) };
            if exception() || length < 0 || length as usize > MAX_PAYLOAD_BYTES {
                return Err(jni_error("Java response exceeds size limit"));
            }
            let chars = unsafe { string_chars(env, reply, ptr::null_mut()) };
            if exception() || chars.is_null() {
                return Err(jni_error("cannot read Java response"));
            }
            let text =
                String::from_utf16(unsafe { std::slice::from_raw_parts(chars, length as usize) });
            unsafe { release_chars(env, reply, chars) };
            let text = text.map_err(|_| jni_error("Java response contains invalid UTF-16"))?;
            if text.len() > MAX_PAYLOAD_BYTES {
                return Err(jni_error("Java response exceeds 8 MiB"));
            }
            Ok(text)
        })();
        unsafe { pop(env, ptr::null_mut()) };
        exception();
        result
    }
}

#[cfg(target_os = "android")]
pub(crate) use android::register;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn native_envelope_preserves_json_and_unicode() {
        let expected = serde_json::json!({"title":"月兔🎧", "null":null, "array":[1,true]});
        let reply = serde_json::json!({"ok":true,"result":expected}).to_string();
        assert_eq!(decode_reply(&reply).unwrap(), expected);
        assert_eq!(
            decode_reply(r#"{"ok":true,"result":null}"#).unwrap(),
            Value::Null
        );
    }

    #[test]
    fn native_envelope_preserves_errors_and_rejects_malformed_responses() {
        assert_eq!(
            decode_reply(r#"{"ok":false,"error":{"code":"auth","message":"sign in"}}"#)
                .unwrap_err()
                .code,
            ErrorCode::Auth
        );
        assert_eq!(
            decode_reply(r#"{"ok":false,"error":{"code":"busy","message":"busy"}}"#)
                .unwrap_err()
                .code,
            ErrorCode::RateLimited
        );
        for (code, expected) in [
            ("signIn", ErrorCode::Auth),
            ("rateLimited", ErrorCode::RateLimited),
            ("setup", ErrorCode::InvalidArgument),
            ("unavailable", ErrorCode::Network),
        ] {
            let reply =
                serde_json::json!({"ok":false,"error":{"code":code,"message":"native error"}})
                    .to_string();
            assert_eq!(decode_reply(&reply).unwrap_err().code, expected);
        }
        for reply in [
            "null",
            "{}",
            r#"{"ok":true}"#,
            r#"{"ok":false,"error":{}}"#,
            r#"{"ok":"true","result":1}"#,
        ] {
            assert!(decode_reply(reply).is_err(), "{reply}");
        }
        assert!(decode_reply(&" ".repeat(MAX_PAYLOAD_BYTES + 1)).is_err());
    }
}
