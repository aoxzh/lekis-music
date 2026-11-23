import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../../l10n/app_l10n.dart';
import '../../platform/external_url.dart';
import '../../rust/api/core.dart' as core;

const _spotifyCredential = 'lekis.spotify.access_token';
const _appleCredential = 'lekis.apple_music.developer_token';

typedef SpotifySearch = Future<List<core.SpotifyAlbumDto>> Function(
  String album,
  String artist,
  String market,
);

/// A temporary, attributed view of Spotify catalogue results.
class SpotifyCatalogPage extends StatefulWidget {
  const SpotifyCatalogPage({
    super.key,
    this.search,
    this.saveToken,
    this.deleteToken,
    this.hasToken,
    this.openLink,
    this.allowPersistentToken,
  });
  final bool? allowPersistentToken;
  final SpotifySearch? search;
  final Future<void> Function(String)? saveToken;
  final Future<void> Function()? deleteToken;
  final bool Function()? hasToken;
  final Future<bool> Function(String)? openLink;
  @override
  State<SpotifyCatalogPage> createState() => _SpotifyCatalogPageState();
}

class _SpotifyCatalogPageState extends State<SpotifyCatalogPage> {
  final album = TextEditingController();
  final artist = TextEditingController();
  final market = TextEditingController(text: 'SG');
  final token = TextEditingController();
  List<core.SpotifyAlbumDto> results = [];
  bool busy = false;
  bool searched = false;
  bool configured = false;
  String? sessionToken;
  bool apple = false;
  String get credential => apple ? _appleCredential : _spotifyCredential;
  bool get persistent =>
      widget.allowPersistentToken ?? (Platform.isAndroid || Platform.isWindows);
  String? error;

  @override
  void initState() {
    super.initState();
    configured =
        persistent &&
        (widget.hasToken?.call() ??
            core.hasCredential(credentialRef: credential));
  }

  @override
  void dispose() {
    album.dispose();
    artist.dispose();
    market.dispose();
    token.dispose();
    super.dispose();
  }

  void selectSource(bool nextApple) {
    if (apple == nextApple) return;
    setState(() {
      apple = nextApple;
      token.clear();
      sessionToken = null;
      results = [];
      searched = false;
      error = null;
      configured =
          persistent &&
          (widget.hasToken?.call() ??
              core.hasCredential(credentialRef: credential));
    });
  }

  Future<void> save() async {
    final value = token.text.trim();
    if (value.isEmpty) return;
    try {
      if (persistent) {
        await (widget.saveToken?.call(value) ??
            core.setCredential(credentialRef: credential, secret: value));
      } else {
        sessionToken = value;
      }
      token.clear();
      if (mounted) {
        setState(() {
          configured = true;
          error = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => error = context.l10n.pick(
            '无法保存凭据',
            'Could not save the credential',
          ),
        );
      }
    }
  }

  Future<void> remove() async {
    try {
      if (persistent) {
        await (widget.deleteToken?.call() ??
            core.deleteCredential(credentialRef: credential));
      } else {
        sessionToken = null;
      }
      if (mounted) {
        setState(() {
          configured = false;
          results = [];
          searched = false;
          error = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => error = context.l10n.pick(
            '无法删除凭据',
            'Could not remove the credential',
          ),
        );
      }
    }
  }

  Future<void> search() async {
    if (album.text.trim().isEmpty ||
        artist.text.trim().isEmpty ||
        !RegExp(r'^[A-Za-z]{2}$').hasMatch(market.text.trim())) {
      setState(
        () => error = context.l10n.pick(
          '请输入专辑、歌手和两位地区代码',
          'Enter an album, artist, and two-letter market code',
        ),
      );
      return;
    }
    setState(() {
      busy = true;
      searched = false;
      error = null;
      results = [];
    });
    try {
      final found =
          await (widget.search?.call(
                album.text.trim(),
                artist.text.trim(),
                market.text.trim(),
              ) ??
              (apple
                  ? (persistent
                        ? core.searchAppleAlbums(
                            album: album.text.trim(),
                            artist: artist.text.trim(),
                            market: market.text.trim(),
                          )
                        : core.searchAppleAlbumsSession(
                            album: album.text.trim(),
                            artist: artist.text.trim(),
                            market: market.text.trim(),
                            token: sessionToken!,
                          ))
                  : (persistent
                        ? core.searchSpotifyAlbums(
                            album: album.text.trim(),
                            artist: artist.text.trim(),
                            market: market.text.trim(),
                          )
                        : core.searchSpotifyAlbumsSession(
                            album: album.text.trim(),
                            artist: artist.text.trim(),
                            market: market.text.trim(),
                            token: sessionToken!,
                          ))));
      if (mounted) {
        setState(() {
          results = found;
          searched = true;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => error = context.l10n.pick(
            '查询失败，请检查令牌、地区或网络。令牌过期后需要更新。',
            'Search failed. Check the token, market, or connection; expired tokens must be replaced.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.pick('专辑目录', 'Album catalogue'))),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Wrap(
            spacing: 8,
            children: [
              TextButton(
                onPressed: busy ? null : () => selectSource(false),
                child: Text(apple ? 'Spotify' : '✓ Spotify'),
              ),
              TextButton(
                onPressed: busy ? null : () => selectSource(true),
                child: Text(apple ? '✓ Apple Music' : 'Apple Music'),
              ),
            ],
          ),
          Text(
            l10n.pick(
              apple
                  ? '输入你自己的 Apple Music 开发者 token；过期后请更新。'
                  : '使用你自己的 Spotify Web API access token。令牌过期后请更新。',
              apple
                  ? 'Enter your Apple Music developer token; replace it when it expires.'
                  : 'Use your Spotify Web API access token. Replace it when it expires.',
            ),
          ),
          if (!persistent)
            Text(
              l10n.pick(
                '此设备上的令牌只保存在当前页面的内存中，关闭页面后清除。',
                'On this device the token is kept only in memory until this page closes.',
              ),
            ),
          TextField(
            controller: token,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: configured
                  ? l10n.pick('更新令牌', 'Replace token')
                  : 'Access token',
            ),
          ),
          Wrap(
            spacing: 8,
            children: [
              TextButton(
                onPressed: save,
                child: Text(
                  persistent
                      ? l10n.pick('安全保存', 'Save securely')
                      : l10n.pick('用于本次查询', 'Use for this session'),
                ),
              ),
              if (configured)
                TextButton(
                  onPressed: remove,
                  child: Text(l10n.pick('删除令牌', 'Remove token')),
                ),
            ],
          ),
          TextField(
            controller: album,
            decoration: InputDecoration(labelText: l10n.pick('专辑', 'Album')),
          ),
          TextField(
            controller: artist,
            decoration: InputDecoration(labelText: l10n.pick('歌手', 'Artist')),
          ),
          TextField(
            controller: market,
            decoration: InputDecoration(
              labelText: l10n.pick('地区（如 SG）', 'Market (e.g. SG)'),
            ),
            maxLength: 2,
          ),
          FilledButton(
            onPressed: busy || !configured ? null : search,
            child: Text(l10n.pick('搜索专辑', 'Search albums')),
          ),
          if (busy) const LinearProgressIndicator(),
          if (error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(error!),
            ),
          if (searched && results.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(l10n.pick('没有找到专辑', 'No albums found')),
            ),
          if (results.isNotEmpty && apple)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('Apple Music'),
            ),
          if (results.isNotEmpty && !apple)
            Container(
              color: Colors.black,
              padding: const EdgeInsets.all(16),
              alignment: Alignment.centerLeft,
              child: Image.asset(
                'assets/spotify/spotify_white.png',
                width: 100,
                fit: BoxFit.contain,
              ),
            ),
          for (final result in results)
            ListTile(
              leading: result.imageUrl == null
                  ? const Icon(Icons.album_outlined)
                  : ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: Image.network(
                        result.imageUrl!,
                        width: 56,
                        height: 56,
                        fit: BoxFit.contain,
                        errorBuilder: (_, _, _) =>
                            const Icon(Icons.album_outlined),
                      ),
                    ),
              title: Text(result.title),
              subtitle: Text(
                '${result.artists.join(', ')}${result.releaseDate == null ? '' : ' · ${result.releaseDate}'}',
              ),
              trailing: const Icon(Icons.open_in_new),
              onTap: () async {
                final ok =
                    await (widget.openLink?.call(result.spotifyUrl) ??
                        openExternalUrl(result.spotifyUrl));
                if (!ok && context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(l10n.pick('无法打开链接', 'Could not open link')),
                    ),
                  );
                }
              },
            ),
        ],
      ),
    );
  }
}
