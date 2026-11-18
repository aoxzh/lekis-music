//! 合并：字段级"最后写入者胜"（LWW）。

use crate::{EntityKind, Hlc, SyncOp};
use std::collections::BTreeMap;

/// 合并后某个字段的最终状态。
#[derive(Debug, Clone, PartialEq)]
pub struct FieldState {
    /// 最终值（`None` 表示已删除）。
    pub value: Option<serde_json::Value>,
    /// 决定这个值的操作时间戳。
    pub hlc: Hlc,
}

/// 字段键：(实体类型, 实体 ID, 字段名)。
pub type FieldKey = (EntityKind, String, String);

/// 合并一组操作（来自任意设备、任意顺序），得到每个字段的最终状态。
///
/// 性质：结果与操作的输入顺序无关（交换律、结合律、幂等），所以各设备最终一定收敛到同一状态。
pub fn merge<'a>(ops: impl IntoIterator<Item = &'a SyncOp>) -> BTreeMap<FieldKey, FieldState> {
    let mut out: BTreeMap<FieldKey, FieldState> = BTreeMap::new();
    for op in ops {
        let key = (op.entity, op.entity_id.clone(), op.field.clone());
        match out.get(&key) {
            Some(existing) if existing.hlc >= op.hlc => {}
            _ => {
                out.insert(
                    key,
                    FieldState {
                        value: op.value.clone(),
                        hlc: op.hlc.clone(),
                    },
                );
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn op(wall: i64, device: &str, value: serde_json::Value) -> SyncOp {
        SyncOp {
            hlc: Hlc {
                wall_ms: wall,
                counter: 0,
                device: device.into(),
            },
            entity: EntityKind::TrackState,
            entity_id: "mb:abc".into(),
            field: "loved".into(),
            value: Some(value),
        }
    }

    #[test]
    fn order_independent() {
        let ops = [
            op(1, "phone", json!(true)),
            op(3, "pc", json!(false)),
            op(2, "phone", json!(true)),
        ];
        let forward = merge(ops.iter());
        let backward = merge(ops.iter().rev());
        assert_eq!(forward, backward);
        let state = forward.values().next().map(|s| s.value.clone());
        assert_eq!(state, Some(Some(json!(false))));
    }
}
