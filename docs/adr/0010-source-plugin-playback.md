# ADR-0010: Connect source plugins to native playback

Status: proposed (local implementation; no upstream review)

## Context

The JS sandbox exposes source capability names, but the app only manages plugin files and settings. Playback assumes all non-filesystem sources are media servers. The SDK already specifies desktop process permissions and a spawn function, without a runtime implementation.

## Decision

API 1.1 adds an optional search limit and implements the existing desktop spawn contract. API 1.0 manifests remain compatible. No new crate or database migration is required.

Source search returns ordinary library rows. An append-only remote-track operation keeps previous search results referenced by queues and playlists. Plugin identity lives in the source configuration, and external song IDs remain opaque. Resolution invokes stream before playback and validates returned hosts, header-host declarations, and expiry. The existing range reader and decoder consume the result.

Runtime construction merges persisted app settings into the plugin defaults. Runtime caches are replaced when source, settings, or process grants change, while per-plugin JSON storage survives restart and runtime replacement. Storage quotas count both key and value bytes. Writes use private Unix permissions and atomic replacement; storage is not encrypted. An owned task retains the per-plugin gate through execution and persistence even if its caller is cancelled.

Process grants are separate host settings, disabled by default and cleared on uninstall. Both declaration and grant are required. Programs run as the current OS user, without a shell or stdin, with a 45-second timeout and independent 8 MiB stdout/stderr limits. An external program is not confined by the JS network permission list. Mobile returns unsupported. App-level source calls allow 60 seconds; standalone JS runtimes keep their existing 15-second default.

## Consequences

The UI can search a selected plugin and reuse normal queue controls, favorites and playlists. Catalog search results are stored locally; signed stream URLs are not. Search consumes the first page of tracks and preserves optional `artworkUrl` metadata. Artwork is fetched on demand through the existing artwork/hash/path API, cached as 128/256/512/1024 WebP tiers and attached to the ordinary track artwork reference. The downloader validates the installed plugin network permissions on every redirect, rejects URL credentials, bounds bytes, dimensions and decoded allocations, and limits concurrent requests to four with same-track deduplication. Failures do not hide playable tracks; a 30-second retry delay prevents event-driven retry storms. Search refresh and background playback refresh repair legacy imports without overwriting manual covers. No image URL is exposed through new frontend DTO fields. The generic browse facade imports stable track rows; MyGO sources expose public folders/collections and cursor paging in the app. Account sign-in and WASM remain unsupported.

A manual generic smoke tool verifies the real JS host and native decoder without an audio output device. Third-party source packages remain outside the upstream repository, consistent with its contribution policy.

## MyGO protocol compatibility

Recognize original MyGO manifests and adapt their documented JavaScript interface without copying AGPL implementation code. Normalize short IDs into a reserved namespace. Adapt source search/stream, public home and collection browsing, JSON storage, translations, MD5, platform and standard URL/fetch helpers. Unsupported login, remote playback, long-running process handles and module imports fail explicitly. No service-specific plugin ships in the core repository.

The small `md-5` 0.10 dependency (MIT OR Apache-2.0) implements the digest required by compatibility APIs; it is not used for cryptographic security. Existing reqwest permission checks apply to every fetch redirect; response and process output sizes remain bounded. Each blocking JS execution owns its serialization guard through completion.

Plugin track identity is based on portable plugin ID and case-sensitive provider track ID rather than mutable metadata. Metadata refreshes preserve local track IDs, favorites and queue references; distinct provider IDs do not collapse solely because their titles match. Native media resolution can fall back when an unavailable plugin candidate has alternatives.

## Validation and limits

Unit tests cover storage restart/error/cancellation behavior, quota and permissions, compatibility mappings and browse identity. Offline plugin tests and live smoke runs use the real QuickJS host and Rust decoder without sending audio to an output device. Full macOS application packaging requires Xcode and remains a separate environment check.
