using Lekis.Core;

namespace Lekis.App.Services;

/// <summary>
/// 本机数据 / 缓存目录。主数据库必须在本机磁盘上（ADR-0004），所以这里永远不能指向网络路径。
/// </summary>
public static class AppPaths
{
    private static string Root => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Lekis");

    // TODO(MSIX)：打包后改用 ApplicationData.Current.LocalFolder / LocalCacheFolder。
    public static string DataDir => Path.Combine(Root, "data");
    public static string CacheDir => Path.Combine(Root, "cache");

    public static CoreOptions CoreOptions() => new(DataDir, CacheDir, Environment.MachineName);
}
