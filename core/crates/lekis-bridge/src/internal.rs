//! 桥接层内部的辅助类型。放在 `api` 模块之外，frb 才不会把它们导出给 Dart。

use std::sync::OnceLock;

use crate::api::dto::CoreEventDto;
use crate::frb_generated::StreamSink;

pub(crate) static CORE: OnceLock<lekis_core::LekisCore> = OnceLock::new();

/// 取核心实例。没调用 [`init_core`] 就调用其他函数属于编程错误。
#[allow(clippy::expect_used)]
pub(crate) fn core() -> &'static lekis_core::LekisCore {
    CORE.get().expect("init_core must be called first")
}

pub(crate) struct SinkListener(pub(crate) StreamSink<CoreEventDto>);

impl lekis_core::EventListener for SinkListener {
    fn on_event(&self, event: lekis_types::CoreEvent) {
        let _ = self.0.add(event.into());
    }
}

