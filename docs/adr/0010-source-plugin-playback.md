# ADR-0010: Source plugin search and playback contract

Status: proposed

## Context

The plugin SDK declares source search and stream capabilities, but the host does not yet connect them to the normal library and playback flow. Source results must remain usable in queues and playlists, while stream URLs can expire and may carry sensitive request headers. Some source plugins also need the SDK's already-declared desktop process API, which the host does not currently implement.

## Proposed decision

Extend plugin API 1.1 with an optional search limit; retain API 1.0 compatibility. Import search results as normal library tracks with a stable identity derived from the plugin ID and the opaque, case-sensitive provider track ID. Refreshing metadata must preserve local track IDs and references, and a new search must not delete previously referenced results.

Resolve the stream when playback starts instead of persisting signed URLs. Check the returned URL against the plugin's network permissions, check request headers against the declared header-host permissions, and reject expired results before passing them to the existing native HTTP range reader and decoder.

Implement the existing desktop `host.spawn` contract with a separate, default-denied user grant for each declared program. Run as the current user, without a shell or stdin; apply a 45-second timeout and independent 8 MiB stdout and stderr limits. A spawned process is not confined by the JavaScript network allowlist. Mobile reports this operation as unsupported. Revoking the grant prevents later calls, and uninstall clears the grant.

Persist per-plugin JSON storage across runtime replacement and restart, with quotas counting key and value bytes. Save atomically with private Unix permissions. Storage is not encrypted and must not be presented as a credential vault. Runtime settings and grants are host-owned; their changes invalidate cached runtimes. Preserve per-plugin serialization through execution and persistence when the caller is cancelled.

## Consequences and boundaries

The proposed flow reuses existing track, queue, playlist and playback machinery. Search initially imports the first page of tracks. No new crate or database migration is proposed. Process access is privileged and optional, not a sandbox for external programs.

MyGO compatibility, artwork ingestion, browsing and Android native extensions are separate proposals and are not approved by this decision. No third-party streaming source plugin is included in the repository.

## Validation required before implementation is merged

Test API 1.0 compatibility, source identity and refresh, queue references, URL and header permission checks, expiration, storage quotas and restart/cancellation behavior, and process grant, timeout and output limits. Exercise the real JavaScript host and decoder with a generic test plugin. Review the permission experience and privacy implications before enabling this path.
