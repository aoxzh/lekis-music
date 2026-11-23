# ADR-0011: Optional Android native plugin extensions

Status: proposed (local implementation; no upstream review)

## Context

Some source providers require JVM libraries for media extraction. Android cannot use the desktop process API. Keeping provider-specific libraries in separately installed plugins lets the generic application evolve independently of each provider.

## Decision

Plugin API 1.2 adds optional `native.android.entry` (a relative `.dex` file or `.jar` containing `classes.dex`, `classes2.dex`, and so on) and `native.android.className` manifest fields. The JavaScript API exposes `host.native.available` and `host.native.call(operation, params)`. The installed manifest determines the entry; JavaScript cannot select a file or class. Existing API 1.0/1.1 plugins remain compatible.

The Android entry implements `public static String invoke(String operation, String payloadJson)`. Parameters and results are JSON. Success is `{"ok":true,"result":...}`; failure is `{"ok":false,"error":{"code":"unavailable","message":"..."}}`. The native bridge uses UTF-16 JNI strings so multilingual text and supplementary Unicode characters survive the round trip.

Execution requires the separate host-owned `plugin.native.<pluginId>.android` grant, disabled by default. A manifest declaration is not a grant. The plugin detail sheet exposes the grant on Android and describes the actual trust boundary: native code runs with application privileges, including application data and unrestricted network access. The JavaScript domain sandbox does not constrain native code. Grant changes invalidate runtime caches and uninstall clears the grant. Revocation blocks subsequent calls; it does not terminate code already executing.

Installation and runtime entry checks reject absolute paths, traversal and symbolic links, requiring a regular file inside the installed plugin directory. Android copies DEX content to private code-cache storage, addresses it by SHA-256 and makes it read-only before loading, including on Android 14+. The loader cache also includes the entry class. Multi-DEX JAR containers permit desugared Java dependencies. Container entries and decompressed sizes are validated before loading. Plugin ZIPs must contain their runtime dependencies in the DEX or DEX container; they cannot assume provider-specific libraries are bundled in the host.

Requests and responses are bounded, and the Android runner accepts one native invocation at a time with a 30-second wait limit. Timing out does not kill arbitrary native code or release its execution slot: further calls remain busy until that code returns. This prevents an unresponsive plugin from creating an unbounded number of workers, but native extensions are trusted application code, not a security sandbox.

## Consequences

YouTube extraction can be distributed as an independent plugin with an Android DEX and a desktop JavaScript path. No YouTube-specific extractor or dependency is included in the application. iOS native extensions are outside this change. The existing Rust media decoder and range reader remain in use; a signed media URL that rejects HEAD is probed with a bounded ranged GET before it is considered unavailable.

Native-extension code must be trusted, and updates need the same scrutiny as installation. Disabling/removing a plugin stops future host calls; restarting the app is required to unload classes or stop persistent behavior started by native code. This API does not provide isolation, forced cancellation, or a general-purpose background service lifecycle.

## Validation

Host tests cover manifest/entry validation, default-denied grants and invalidation. Android bridge tests cover single-worker timeout behavior, Unicode/error envelopes and immutable DEX caching. Playback tests cover signed URLs that reject HEAD but allow ranged GET. Release notes must distinguish successful offline tests, APK builds and actual online/device playback checks; none implies the others.
