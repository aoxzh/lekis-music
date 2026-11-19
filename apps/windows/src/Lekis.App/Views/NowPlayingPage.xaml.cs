using System.ComponentModel;
using Lekis.App.ViewModels;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;

namespace Lekis.App.Views;

/// <summary>
/// 正在播放页。播放控制全部委托给 <see cref="PlayerViewModel"/>，和底部播放条共用同一份状态。
/// 进度条拖动期间只更新滑块，松手才 seek（同 PlayerBar 的理由：拖动中反复 seek 会刷爆核心命令通道）。
/// </summary>
public sealed partial class NowPlayingPage : Page
{
    private bool _syncingPosition;
    private bool _dragging;

    public NowPlayingPage()
    {
        ViewModel = App.Services.GetRequiredService<PlayerViewModel>();
        InitializeComponent();

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
