using System.ComponentModel;
using Lekis.App.ViewModels;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;

namespace Lekis.App.Controls;

/// <summary>
/// 底部播放条。只做"显示 + 把手势转成 ViewModel 调用"，播放控制本身在 <see cref="PlayerViewModel"/>。
/// 进度条：ViewModel 的位置变化回写滑块；用户拖动时先只改滑块，松手才 seek（拖动中反复 seek 会把核心命令通道刷爆）。
/// </summary>
public sealed partial class PlayerBar : UserControl
{
    private bool _syncingPosition;
    private bool _dragging;

    public PlayerBar()
    {
        ViewModel = App.Services.GetRequiredService<PlayerViewModel>();
        InitializeComponent();

        // Slider 自己会吃掉 PointerPressed / PointerReleased，handledEventsToo 才能收到。
        PositionSlider.AddHandler(PointerPressedEvent, new PointerEventHandler(OnSliderPointerPressed), handledEventsToo: true);
        PositionSlider.AddHandler(PointerReleasedEvent, new PointerEventHandler(OnSliderPointerReleased), handledEventsToo: true);
        PositionSlider.PointerCaptureLost += (_, _) => FinishDrag();

        ViewModel.PropertyChanged += OnViewModelPropertyChanged;
        Unloaded += (_, _) => ViewModel.PropertyChanged -= OnViewModelPropertyChanged;

        SyncPositionFromViewModel();
    }

    public PlayerViewModel ViewModel { get; }

    private void OnViewModelPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(PlayerViewModel.PositionMs) or nameof(PlayerViewModel.DurationMs))
        {
            SyncPositionFromViewModel();
        }
    }

    /// <summary>把 ViewModel 的位置回写到滑块（拖动中不回写，否则手指会被拽回去）。</summary>
    private void SyncPositionFromViewModel()
    {
        if (_dragging) return;
        _syncingPosition = true;
        try
        {
            PositionSlider.Value = ViewModel.PositionMs;
        }
        finally
        {
            _syncingPosition = false;
        }
    }

    private void OnPositionChanged(object sender, RangeBaseValueChangedEventArgs e)
    {
        if (_syncingPosition || _dragging) return;
        // 点击轨道 / 键盘调整：没有拖动过程，直接 seek。
        ViewModel.SeekTo(e.NewValue);
    }

    private void OnSliderPointerPressed(object sender, PointerRoutedEventArgs e) => _dragging = true;

    private void OnSliderPointerReleased(object sender, PointerRoutedEventArgs e) => FinishDrag();

    private void FinishDrag()
    {
        if (!_dragging) return;
        _dragging = false;
        ViewModel.SeekTo(PositionSlider.Value);
    }
}
