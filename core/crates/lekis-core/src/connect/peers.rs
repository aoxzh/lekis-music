//! 已配对设备。
//!
//! 设备名、平台、配对时间放在数据目录的 `connect_peers.json`（不是秘密）；
//! 长期密钥放进平台凭据库（`connect.peer.<设备 ID>`），和音源密码同一个地方。

use crate::platform::CredentialStore;
use lekis_types::Result;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

/// 一台已配对的设备。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PairedPeer {
    /// 设备 ID。
    pub device_id: String,
    /// 配对时的设备名。
    pub name: String,
    /// 平台。
    pub platform: String,
    /// 配对时间（Unix 毫秒）。
    pub paired_at_ms: i64,
}

pub(crate) struct PeerStore {
    path: PathBuf,
    credentials: Arc<dyn CredentialStore>,
    peers: Mutex<BTreeMap<String, PairedPeer>>,
}

fn credential_key(device_id: &str) -> String {
    format!("connect.peer.{device_id}")
}

impl PeerStore {
    pub(crate) fn open(path: PathBuf, credentials: Arc<dyn CredentialStore>) -> Self {
        let peers = std::fs::read(&path)
            .ok()
            .and_then(|raw| serde_json::from_slice::<Vec<PairedPeer>>(&raw).ok())
            .unwrap_or_default()
            .into_iter()
            .map(|p| (p.device_id.clone(), p))
            .collect();
        Self {
            path,
            credentials,
            peers: Mutex::new(peers),
        }
    }

    pub(crate) fn list(&self) -> Vec<PairedPeer> {
        self.peers
            .lock()
            .map(|p| p.values().cloned().collect())
            .unwrap_or_default()
    }

    /// 长期密钥；没配对过（或者凭据库里丢了）返回 `None`。
    pub(crate) fn key(&self, device_id: &str) -> Option<Vec<u8>> {
        let known = self
            .peers
            .lock()
            .map(|p| p.contains_key(device_id))
            .unwrap_or(false);
        if !known {
            return None;
        }
        self.credentials
            .get(&credential_key(device_id))
            .and_then(|hexed| hex::decode(hexed).ok())
            .filter(|k| !k.is_empty())
    }

    pub(crate) fn save(&self, peer: PairedPeer, key: &[u8]) -> Result<()> {
        self.credentials
            .set(&credential_key(&peer.device_id), &hex::encode(key))?;
        if let Ok(mut peers) = self.peers.lock() {
            peers.insert(peer.device_id.clone(), peer);
        }
        self.persist()
    }

    pub(crate) fn forget(&self, device_id: &str) -> Result<()> {
        let _ = self.credentials.delete(&credential_key(device_id));
        if let Ok(mut peers) = self.peers.lock() {
            peers.remove(device_id);
        }
        self.persist()
    }

    fn persist(&self) -> Result<()> {
        let list = self.list();
        let json = serde_json::to_vec_pretty(&list)
            .map_err(|e| lekis_types::LekisError::internal(format!("encode peers: {e}")))?;
        let tmp = self.path.with_extension("json.tmp");
        std::fs::write(&tmp, json)?;
        std::fs::rename(&tmp, &self.path)?;
        Ok(())
    }
}
