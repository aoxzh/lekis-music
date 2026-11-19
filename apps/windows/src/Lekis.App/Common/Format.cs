using Lekis.Core;
using Microsoft.UI.Xaml;
using Microsoft.Windows.ApplicationModel.Resources;

namespace Lekis.App.Common;

/// <summary>x:Bind 函数绑定用的格式化工具。只做显示格式化，不做业务判断。</summary>
public static class Format
{
    public static string Duration(long ms)
    {
        var t = TimeSpan.FromMilliseconds(Math.Max(0, ms));
        return t.TotalHours >= 1 ? t.ToString(@"h\:mm\:ss") : t.ToString(@"m\:ss");
    }

    public static string DurationD(double ms) => Duration((long)ms);

    public static string Subtitle(TrackRow? t) =>
        t is null ? string.Empty
        : string.IsNullOrEmpty(t.AlbumTitle) ? t.ArtistLine
        : $"{t.ArtistLine} · {t.AlbumTitle}";

    public static Visibility VisibleIfText(string? s) => string.IsNullOrEmpty(s) ? Visibility.Collapsed : Visibility.Visible;

    public static Visibility VisibleIfTrue(bool b) => b ? Visibility.Visible : Visibility.Collapsed;

    public static Visibility VisibleIfFalse(bool b) => b ? Visibility.Collapsed : Visibility.Visible;

    /// <summary>数字为 0 时可见（空队列提示用）。x:Bind 的函数绑定不支持嵌套调用，所以拆成单层。</summary>
    public static Visibility VisibleIfZero(int value) => value == 0 ? Visibility.Visible : Visibility.Collapsed;

    /// <summary>数字大于 0 时可见。</summary>
    public static Visibility VisibleIfPositive(int value) => value > 0 ? Visibility.Visible : Visibility.Collapsed;

    /// <summary>播放 / 暂停按钮图标（Segoe Fluent Icons）。</summary>
    public static string PlayPauseGlyph(bool isPlaying) => isPlaying ? "" : "";
}

/// <summary>本地化字符串。所有给用户看的文字都放在 Strings/*/Resources.resw 里。</summary>
public static class Strings
{
    private static readonly ResourceLoader Loader = new();

    public static string Get(string key)
    {
        var s = Loader.GetString(key);
        return string.IsNullOrEmpty(s) ? key : s;
    }

    /// <summary>核心错误 → 用户能看懂的提示。不要把 Exception.Message 直接显示给用户。</summary>
    public static string ErrorMessage(Exception e) => e switch
    {
        CoreServiceException c => Get($"Error_{c.Kind}"),
        _ => Get("Error_Internal"),
    };
}
