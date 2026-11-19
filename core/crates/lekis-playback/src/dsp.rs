//! DSP 链。每个节点原地处理一块 f32 交错样本。
//!
//! 节点在解码线程上运行，不在实时线程上，但仍然要求：`process` 里不分配内存。
//! 比特完美模式（PLY-05）下整条 DSP 链被跳过。

/// DSP 节点。
pub trait DspNode: Send {
    /// 原地处理样本。`channels` 是声道数，`samples.len()` 是声道数的整数倍。
    fn process(&mut self, samples: &mut [f32], channels: u16);

    /// 切歌或跳转时重置内部状态（滤波器历史等）。
    fn reset(&mut self) {}
}

/// 把 dB 转成线性增益。
pub fn db_to_linear(db: f32) -> f32 {
    10f32.powf(db / 20.0)
}

/// ReplayGain / 音量节点（PLY-03）。
#[derive(Debug, Clone)]
pub struct Gain {
    linear: f32,
}

impl Gain {
    /// 用 dB 值创建。
    pub fn from_db(db: f32) -> Self {
        Self {
            linear: db_to_linear(db),
        }
    }

    /// 修改增益。
    pub fn set_db(&mut self, db: f32) {
        self.linear = db_to_linear(db);
    }
}

impl DspNode for Gain {
    fn process(&mut self, samples: &mut [f32], _channels: u16) {
        if (self.linear - 1.0).abs() < f32::EPSILON {
            return;
        }
        for s in samples.iter_mut() {
            *s *= self.linear;
        }
    }
}

/// 简单的软限幅器，防止 ReplayGain 正增益或 EQ 导致削波（PLY-03 防削波）。
///
/// TODO：换成带前瞻（look-ahead）的真正限幅器。
#[derive(Debug, Clone, Default)]
pub struct SoftClipper;

impl DspNode for SoftClipper {
    fn process(&mut self, samples: &mut [f32], _channels: u16) {
        for s in samples.iter_mut() {
            let x = *s;
            if x.abs() > 0.9 {
                // 0.9 以上用 tanh 曲线压到 (−1, 1)。
                *s = x.signum() * (0.9 + 0.1 * ((x.abs() - 0.9) / 0.1).tanh());
            }
        }
    }
}

/// DSP 链。
#[derive(Default)]
pub struct DspChain {
    nodes: Vec<Box<dyn DspNode>>,
}

impl DspChain {
    /// 追加节点。
    pub fn push(&mut self, node: Box<dyn DspNode>) {
        self.nodes.push(node);
    }

    /// 依次执行所有节点。
    pub fn process(&mut self, samples: &mut [f32], channels: u16) {
        for node in &mut self.nodes {
            node.process(samples, channels);
        }
    }

    /// 重置所有节点。
    pub fn reset(&mut self) {
        for node in &mut self.nodes {
            node.reset();
        }
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;

    #[test]
    fn gain_and_clip() {
        let mut chain = DspChain::default();
        chain.push(Box::new(Gain::from_db(6.0)));
        chain.push(Box::new(SoftClipper));
        let mut buf = vec![0.1, -0.1, 0.9, -0.9];
        chain.process(&mut buf, 2);
        assert!((buf[0] - 0.1995).abs() < 0.001);
        // 软限幅的渐近线是满刻度 1.0，f32 精度下大信号会正好等于 1.0，但绝不能超过。
        assert!(buf.iter().all(|s| s.abs() <= 1.0));
    }
}
