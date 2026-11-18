using CommunityToolkit.Mvvm.ComponentModel;
using Lekis.App.Services;
using Lekis.Core;

namespace Lekis.App.ViewModels;

/// <summary>
/// 补全结果待确认队列（REQUIREMENTS ENR-06：置信度 0.5–0.85 的候选需要用户确认）。
/// TODO(ENR-*)：核心暴露 list_enrich_candidates / accept / reject 之后，在这里列出候选（当前值 vs 候选值对比、
/// 来源、置信度），支持批量接受。
/// </summary>
public sealed partial class EnrichReviewViewModel : ObservableObject
{
    public EnrichReviewViewModel(ICoreService core, IUiDispatcher ui)
    {
        core.EventReceived += (_, e) =>
        {
            if (e is CoreEvent.EnrichQueueChanged q) ui.Post(() => Pending = q.Pending);
        };
    }

    [ObservableProperty]
    public partial int Pending { get; set; }
}
