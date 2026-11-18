namespace Lekis.Core;

/// <summary>
/// 创建 <see cref="ICoreService"/>。App 只通过这里拿核心，不需要知道绑定是否存在。
/// </summary>
public static class CoreServiceFactory
{
    /// <summary>
    /// 绑定（Generated/lekis_ffi.cs）在编译时存在 → 真实核心；否则 → <see cref="FakeCoreService"/>。
    /// 绑定存在但 lekis_ffi.dll 加载失败时<b>不会</b>静默降级，而是抛出异常——发布版里用假数据比崩溃更糟。
    /// </summary>
    public static ICoreService Create(CoreOptions options)
    {
#if LEKIS_BINDINGS
        return new RustCoreService(options, new WindowsCredentialStore());
#else
        _ = options;
        return new FakeCoreService();
#endif
    }
}
