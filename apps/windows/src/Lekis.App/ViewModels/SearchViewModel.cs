using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using Lekis.Core;

namespace Lekis.App.ViewModels;

/// <summary>
/// 搜索。输入停顿 <see cref="DebounceMs"/> 毫秒后查询；旧查询的结果晚到时直接丢弃。
/// 拼音 / 简繁 / 首字母匹配都在核心里做（lekis-library normalize.rs），这里不要做任何文本处理。
/// </summary>
public sealed partial class SearchViewModel : ObservableObject
{
    private const int DebounceMs = 250;
    private readonly ICoreService _core;
    private readonly PlayerViewModel _player;
    private CancellationTokenSource? _pending;

    public SearchViewModel(ICoreService core, PlayerViewModel player)
    {
        _core = core;
        _player = player;
        Query = string.Empty;
    }

    [ObservableProperty]
    public partial string Query { get; set; }

    [ObservableProperty]
    public partial bool IsEmpty { get; set; }

    public ObservableCollection<TrackRow> Results { get; } = [];

    partial void OnQueryChanged(string value) => _ = SearchAsync(value);

    public void Play(TrackRow track)
    {
        var ids = Results.Select(t => t.Id).ToList();
        var index = ids.IndexOf(track.Id);
        if (index >= 0) _player.PlayTracks(ids, index);
    }

    private async Task SearchAsync(string text)
    {
        _pending?.Cancel();
        var cts = _pending = new CancellationTokenSource();
        try
        {
            await Task.Delay(DebounceMs, cts.Token);
            IReadOnlyList<TrackRow> found = string.IsNullOrWhiteSpace(text) ? [] : await _core.SearchAsync(text.Trim());
            if (cts.IsCancellationRequested) return;
            Results.Clear();
            foreach (var t in found) Results.Add(t);
            IsEmpty = found.Count == 0 && !string.IsNullOrWhiteSpace(text);
        }
        catch (OperationCanceledException)
        {
        }
        catch (CoreServiceException)
        {
            Results.Clear();
            IsEmpty = true;
        }
    }
}
