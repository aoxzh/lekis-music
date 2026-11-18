using System.Collections.ObjectModel;
using System.Runtime.InteropServices.WindowsRuntime;
using Lekis.Core;
using Microsoft.UI.Xaml.Data;
using Windows.Foundation;

namespace Lekis.App.Common;

/// <summary>
/// 分页加载的歌曲列表：ListView 滚到底部时自动调用 <see cref="LoadMoreItemsAsync"/>。
/// 10 万首也只在内存里保留已经滚过的部分（docs/ARCHITECTURE.md 第 4 节"大列表"）。
/// 必须在 UI 线程上使用。
/// </summary>
public sealed class TrackPager(Func<int, int, Task<IReadOnlyList<TrackRow>>> fetch, int pageSize)
    : ObservableCollection<TrackRow>, ISupportIncrementalLoading
{
    private bool _loading;

    public bool HasMoreItems { get; private set; } = true;

    /// <summary>最近一次加载失败的错误（UI 可以显示重试条）。</summary>
    public Exception? LastError { get; private set; }

    public IAsyncOperation<LoadMoreItemsResult> LoadMoreItemsAsync(uint count) =>
        AsyncInfo.Run(async _ =>
        {
            if (_loading || !HasMoreItems) return new LoadMoreItemsResult { Count = 0 };
            _loading = true;
            try
            {
                var page = await fetch(Count, pageSize);
                foreach (var t in page) Add(t);
                HasMoreItems = page.Count == pageSize;
                LastError = null;
                return new LoadMoreItemsResult { Count = (uint)page.Count };
            }
            catch (Exception e)
            {
                LastError = e;
                HasMoreItems = false;
                return new LoadMoreItemsResult { Count = 0 };
            }
            finally
            {
                _loading = false;
            }
        });
}
