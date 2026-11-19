using Microsoft.UI.Xaml.Data;

namespace Lekis.App.Common;

/// <summary>
/// 枚举 → 本地化文本：键名格式 <c>{Prefix}_{成员名}</c>（例如 <c>Sort_RecentlyAdded</c>）。
/// 只用于显示；缺键时退回 <see cref="Strings.Get"/> 的兜底（显示键名，方便发现漏翻）。
/// </summary>
public sealed class EnumTextConverter : IValueConverter
{
    /// <summary>resw 里的键名前缀，例如 Sort / SourceKind。</summary>
    public string Prefix { get; set; } = string.Empty;

    public object Convert(object value, Type targetType, object parameter, string language) =>
        value is null ? string.Empty : Strings.Get($"{Prefix}_{value}");

    public object ConvertBack(object value, Type targetType, object parameter, string language) =>
        throw new NotSupportedException("枚举显示文本只做单向转换。");
}
