using Microsoft.UI.Dispatching;

namespace Lekis.App.Services;

/// <summary>
/// 切回 UI 线程。核心事件在核心的线程上触发，ViewModel 收到后必须通过它再改可绑定属性。
/// 单元测试里换成直接执行的实现。
/// </summary>
public interface IUiDispatcher
{
    void Post(Action action);
}

public sealed class DispatcherQueueUiDispatcher(DispatcherQueue queue) : IUiDispatcher
{
    public void Post(Action action)
    {
        if (queue.HasThreadAccess)
        {
            action();
        }
        else
        {
            queue.TryEnqueue(() => action());
        }
    }
}
