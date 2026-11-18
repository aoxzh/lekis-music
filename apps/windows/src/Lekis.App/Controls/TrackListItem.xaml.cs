using Lekis.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Lekis.App.Controls;

public sealed partial class TrackListItem : UserControl
{
    public static readonly DependencyProperty TrackProperty = DependencyProperty.Register(
        nameof(Track), typeof(TrackRow), typeof(TrackListItem), new PropertyMetadata(null));

    public TrackListItem()
    {
        InitializeComponent();
    }

    public TrackRow? Track
    {
        get => (TrackRow?)GetValue(TrackProperty);
        set => SetValue(TrackProperty, value);
    }
}
