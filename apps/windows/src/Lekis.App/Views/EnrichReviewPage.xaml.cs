using Lekis.App.ViewModels;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml.Controls;

namespace Lekis.App.Views;

/// <summary>
/// 补全结果待确认队列。现在只显示核心推送的待确认数量，候选对比要等核心的
/// list_enrich_candidates / accept / reject 接口。
/// </summary>
public sealed partial class EnrichReviewPage : Page
{
    public EnrichReviewPage()
    {
        ViewModel = App.Services.GetRequiredService<EnrichReviewViewModel>();
        InitializeComponent();
    }

    public EnrichReviewViewModel ViewModel { get; }
}
