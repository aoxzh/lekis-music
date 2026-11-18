using Lekis.Core;
using Microsoft.UI.Xaml;

namespace Lekis.App.Services;

/// <summary>
/// 系统媒体控制（SMTC：锁屏 / 音量浮层 / 键盘媒体键 / 任务栏缩略图按钮）。REQUIREMENTS PLY-12、PTF-01。
///
/// TODO(PLY-12)：原型阶段是空实现。正式实现：
/// <list type="number">
/// <item>用 <c>SystemMediaTransportControlsInterop.GetForWindow(hwnd)</c> 拿到窗口的 SMTC
///   （核心自己输出音频，不经过 Windows.Media.Playback.MediaPlayer，所以不能用 MediaPlayer 自带的 SMTC）；</item>
/// <item>订阅 <see cref="ICoreService.PlaybackChanged"/>，更新 PlaybackStatus、时间线和 DisplayUpdater（标题、艺人、封面缩略图文件）；</item>
/// <item>ButtonPressed → 调 <see cref="ICoreService"/> 的 Play/Pause/Next/Previous（这是除 PlayerViewModel 外唯一可以调播放控制的地方）。</item>
/// </list>
/// </summary>
public sealed class MediaControlsService(ICoreService core)
{
    private readonly ICoreService _core = core;

    public void Attach(Window window)
    {
        _ = window;
        _ = _core;
    }
}
