package dev.lekis.lekis;

import android.content.Context;
import android.os.Looper;
import dalvik.system.DexClassLoader;
import org.json.JSONObject;
import java.io.File;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * Generic DEX ABI, called by Rust after the per-plugin native-code grant check.
 * Native plugins run with the application's full privileges. No Context is passed into their ABI.
 */
public final class NativePluginBridge {
    private static final int MAX_PAYLOAD_BYTES = 8 * 1024 * 1024;
    private static final NativePluginRunner RUNNER = new NativePluginRunner();
    private static volatile Context application;
    // Only the single runner thread accesses this cache; dependencies resolve through the same loader.
    private static final Map<String, Method> METHODS = new LinkedHashMap<String, Method>(8, 0.75f, true) {
        @Override protected boolean removeEldestEntry(Map.Entry<String, Method> entry) { return size() > 8; }
    };

    private NativePluginBridge() {}

    public static void initialize(Context context) {
        application = context.getApplicationContext();
    }

    /** JNI entry; the caller waits off the UI thread, with a maximum 30-second deadline. */
    public static String call(String pluginRoot, String entry, String className, String operation, String payloadJson) {
        try {
            if (Looper.myLooper() == Looper.getMainLooper()) {
                throw new NativePluginRunner.Failure("unsupported", "Native plugins cannot execute on the main thread");
            }
            if (application == null) throw new NativePluginRunner.Failure("unsupported", "Native bridge is not initialized");
            checkPayload(payloadJson);
            if (operation == null || operation.isEmpty() || operation.getBytes(StandardCharsets.UTF_8).length > 256) {
                throw new NativePluginRunner.Failure("invalid_argument", "Invalid native operation");
            }
            if (className == null || className.length() > 512 ||
                !className.matches("[A-Za-z_$][A-Za-z0-9_$]*(\\.[A-Za-z_$][A-Za-z0-9_$]*)*")) {
                throw new NativePluginRunner.Failure("invalid_argument", "Invalid native entry class");
            }
            return RUNNER.run(() -> invoke(pluginRoot, entry, className, operation, payloadJson), 30_000);
        } catch (Throwable failure) {
            String code = failure instanceof NativePluginRunner.Failure ? ((NativePluginRunner.Failure) failure).code : "plugin";
            String message = failure.getMessage();
            if (message == null) message = failure.getClass().getSimpleName();
            if (message.length() > 2048) message = message.substring(0, 2048);
            try {
                return new JSONObject().put("ok", false).put("error",
                    new JSONObject().put("code", code).put("message", message)).toString();
            } catch (Exception impossible) { return "{\"ok\":false,\"error\":{\"code\":\"plugin\",\"message\":\"Native bridge failed\"}}"; }
        }
    }

    private static String invoke(String rootPath, String entry, String className, String operation, String payload) throws Exception {
        Context context = application;
        File root = new File(rootPath);
        File privateRoot = new File(context.getApplicationInfo().dataDir).getCanonicalFile();
        File canonicalRoot = root.getCanonicalFile();
        if (!canonicalRoot.toPath().startsWith(privateRoot.toPath()) || !root.isDirectory() || Files.isSymbolicLink(root.toPath())) {
            throw new NativePluginRunner.Failure("permission_denied", "Native plugins must reside in app-private storage");
        }
        if (entry == null || !(entry.endsWith(".dex") || entry.endsWith(".jar")) || entry.contains("\\") || entry.contains(":")) {
            throw new NativePluginRunner.Failure("invalid_argument", "Native entry must be a relative .dex file or DEX .jar container");
        }
        File dex = canonicalRoot;
        for (String component : entry.split("/", -1)) {
            if (component.isEmpty() || component.equals(".") || component.equals("..")) {
                throw new NativePluginRunner.Failure("invalid_argument", "Invalid native DEX path");
            }
            dex = new File(dex, component);
            if (Files.isSymbolicLink(dex.toPath())) throw new NativePluginRunner.Failure("permission_denied", "Native DEX path contains a symlink");
        }
        if (!dex.isFile() || !dex.getCanonicalFile().toPath().startsWith(canonicalRoot.toPath())) {
            throw new NativePluginRunner.Failure("not_found", "Native DEX entry does not exist in its plugin directory");
        }
        File cache = new File(context.getCodeCacheDir(), "native-plugins");
        File snapshot = NativePluginDexCache.snapshot(dex, cache);
        String key = snapshot.getName() + ":" + className;
        Method method = METHODS.get(key);
        if (method == null) {
            DexClassLoader loader = new DexClassLoader(snapshot.getPath(), cache.getPath(), null, NativePluginBridge.class.getClassLoader());
            Class<?> entryClass = Class.forName(className, true, loader);
            if (entryClass.getClassLoader() != loader) throw new NativePluginRunner.Failure("invalid_argument", "Entry class must come from plugin DEX");
            method = entryClass.getMethod("invoke", String.class, String.class);
            if (!Modifier.isStatic(method.getModifiers()) || method.getReturnType() != String.class) {
                throw new NativePluginRunner.Failure("invalid_argument", "Native entry must expose public static String invoke(String, String)");
            }
            METHODS.put(key, method);
        }
        String reply;
        try { reply = (String) method.invoke(null, operation, payload); }
        catch (InvocationTargetException failure) {
            Throwable cause = failure.getCause();
            if (cause instanceof Exception) throw (Exception) cause;
            throw new NativePluginRunner.Failure("plugin", "Native plugin failed: " + cause.getClass().getSimpleName());
        }
        checkPayload(reply);
        JSONObject envelope = new JSONObject(reply);
        Object ok = envelope.opt("ok");
        if (!(ok instanceof Boolean) || ((Boolean) ok && !envelope.has("result")) ||
            (!(Boolean) ok && !(envelope.opt("error") instanceof JSONObject))) {
            throw new NativePluginRunner.Failure("plugin", "Native plugin returned an invalid response envelope");
        }
        return reply;
    }

    private static void checkPayload(String value) throws NativePluginRunner.Failure {
        if (value == null || value.length() > MAX_PAYLOAD_BYTES || value.getBytes(StandardCharsets.UTF_8).length > MAX_PAYLOAD_BYTES) {
            throw new NativePluginRunner.Failure("invalid_argument", "Native JSON payload exceeds 8 MiB or is null");
        }
    }
}
