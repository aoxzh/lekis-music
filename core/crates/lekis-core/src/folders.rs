//! 按文件夹浏览（LIB：browse by folder）。数据全部来自资料库的 `file` 表。

use crate::LekisCore;
pub use lekis_library::{FolderEntry, FolderListing, FolderRoot};
use lekis_types::{Result, SourceId, TrackRow};

impl LekisCore {
    /// 文件夹视图的第一层：有曲目的音源。
    pub async fn folder_roots(&self) -> Result<Vec<FolderRoot>> {
        let s = self.services.clone();
        self.run(async move { s.library.folder_roots().await })
            .await
    }

    /// 某个音源下目录 `path`（`""` = 根目录）的子文件夹和直属曲目数。
    pub async fn list_folder(&self, source: SourceId, path: String) -> Result<FolderListing> {
        let s = self.services.clone();
        self.run(async move { s.library.list_folder(source, &path).await })
            .await
    }

    /// 目录的直属曲目（按文件名），分页。
    pub async fn folder_tracks(
        &self,
        source: SourceId,
        path: String,
        offset: u32,
        limit: u32,
    ) -> Result<Vec<TrackRow>> {
        let s = self.services.clone();
        self.run(async move { s.library.folder_tracks(source, &path, offset, limit).await })
            .await
    }
}
