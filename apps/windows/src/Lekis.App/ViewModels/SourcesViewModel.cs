using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using Lekis.App.Common;
using Lekis.App.Services;
using Lekis.Core;

namespace Lekis.App.ViewModels;

/// <summary>
/// 音源管理。原型只支持"添加本地文件夹 + 扫描"。
/// TODO(SRC-*)：局域网 NAS 自动发现（mDNS / WS-Discovery / NetBIOS）、SMB/WebDAV/SFTP 登录对话框（密码只进
/// WindowsCredentialStore）、OpenSubsonic/Jellyfin/Plex 登录、音源优先级拖拽、连通性指示。
/// </summary>
public sealed partial class SourcesViewModel : ObservableObject
{
    private readonly ICoreService _core;

    public SourcesViewModel(ICoreService core, IUiDispatcher ui)
    {
        _core = core;
        _core.EventReceived += (_, e) => ui.Post(() => OnCoreEvent(e));
        _ = RefreshAsync();
    }

    public ObservableCollection<Source> Sources { get; } = [];

    [ObservableProperty]
    public partial string? Status { get; set; }

    public async Task AddLocalFolderAsync(string path, string displayName)
    {
        try
        {
            var id = await _core.AddSourceAsync(new Source(null, SourceKind.Local, displayName, [], path));
            await RefreshAsync();
            await _core.StartScanAsync(id);
        }
        catch (CoreServiceException e)
        {
            Status = Strings.ErrorMessage(e);
        }
    }

    public async Task RescanAsync(Source source)
    {
        if (source.Id is not { } id) return;
        try
        {
            await _core.StartScanAsync(id);
        }
        catch (CoreServiceException e)
        {
            Status = Strings.ErrorMessage(e);
        }
    }

    private async Task RefreshAsync()
    {
        try
        {
            var list = await _core.ListSourcesAsync();
            Sources.Clear();
            foreach (var s in list) Sources.Add(s);
        }
        catch (CoreServiceException e)
        {
            Status = Strings.ErrorMessage(e);
        }
    }

    private void OnCoreEvent(CoreEvent e)
    {
        switch (e)
        {
            case CoreEvent.ScanProgress p:
                Status = string.Format(Strings.Get("Sources_ScanProgress"), p.Done, p.Total?.ToString() ?? "?");
                break;
            case CoreEvent.ScanFinished f:
                Status = string.Format(Strings.Get("Sources_ScanFinished"), f.Added, f.Updated, f.Removed);
                break;
        }
    }
}
