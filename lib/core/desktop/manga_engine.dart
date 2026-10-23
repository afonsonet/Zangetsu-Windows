import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:hive/hive.dart';

import '../logging/app_logger.dart';
import '../platform/app_paths.dart';

/// Windows manga engine: runs Mihon/Tachiyomi extensions (Android DEX) on a
/// bundled Java runtime by hosting Suwayomi-Server on loopback, and translates
/// the app's existing `zangetsu/mihon` method-channel contract onto its GraphQL
/// API. Nothing above this file (MihonProvider, the sources screens) knows the
/// difference — on Android the same calls reach the native bridge instead.
///
/// Layout next to Zangetsu.exe:
///   manga-engine/jre/bin/javaw.exe
///   manga-engine/bin/Suwayomi-Server.jar
/// (put there by the CI build; when missing, [isAvailable] is false and the
/// manga rows stay hidden exactly as before).
class MangaEngine {
  MangaEngine._();
  static final MangaEngine instance = MangaEngine._();

  static String get engineDirectory =>
      '${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}manga-engine';

  static String get _javaPath =>
      '$engineDirectory${Platform.pathSeparator}jre${Platform.pathSeparator}bin${Platform.pathSeparator}javaw.exe';
  static String get _jarPath =>
      '$engineDirectory${Platform.pathSeparator}bin${Platform.pathSeparator}Suwayomi-Server.jar';

  static bool? _available;
  static bool get isAvailable => _available ??= !kIsWeb &&
      Platform.isWindows &&
      File(_javaPath).existsSync() &&
      File(_jarPath).existsSync();

  /// Keiyoushi is the de-facto Mihon extension repo; always offered, plus
  /// whatever repos the user added on the Mihon sources screen.
  static const String _defaultRepo =
      'https://raw.githubusercontent.com/keiyoushi/extensions/repo/index.min.json';

  Process? _proc;
  int? _port;
  Future<void>? _starting;
  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10);

  // Suwayomi addresses manga/chapters by its own database ids, the app by the
  // source-relative url. Remember the pairing from every list we return.
  final Map<String, int> _mangaIds = {};
  final Map<String, int> _chapterIds = {};
  bool _reposApplied = false;

  void _log(String m) => AppLogger.instance.log('[manga-engine] $m');

  // ── process ────────────────────────────────────────────────────────────────

  Future<void> ensureStarted() {
    if (_proc != null && _port != null) return Future.value();
    return _starting ??= _start().whenComplete(() => _starting = null);
  }

  Future<void> _start() async {
    if (!isAvailable) {
      throw PlatformException(
        code: 'ENGINE',
        message: 'The manga engine is missing. Extract the whole app folder.',
      );
    }
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    final support = await getWritableAppDirectory();
    final data = Directory('${support.path}${Platform.pathSeparator}manga-engine');
    await data.create(recursive: true);
    final logFile = File('${data.path}${Platform.pathSeparator}engine.log')
        .openWrite(mode: FileMode.append);
    const p = '-Dsuwayomi.tachidesk.config.server';
    final proc = await Process.start(
      _javaPath,
      [
        '-Xmx768m',
        '-XX:+UseSerialGC',
        '-Dfile.encoding=UTF-8',
        '$p.rootDir=${data.path}',
        '$p.ip=127.0.0.1',
        '$p.port=$port',
        '$p.initialOpenInBrowserEnabled=false',
        '$p.systemTrayEnabled=false',
        '$p.webUIEnabled=false',
        '$p.kcefEnabled=false',
        '-jar',
        _jarPath,
      ],
      workingDirectory: engineDirectory,
    );
    _proc = proc;
    _port = port;
    unawaited(proc.stdout.forEach(logFile.add));
    unawaited(proc.stderr.forEach(logFile.add));
    unawaited(proc.exitCode.then((code) async {
      _log('engine exited ($code)');
      if (identical(_proc, proc)) {
        _proc = null;
        _port = null;
        _reposApplied = false;
      }
      await logFile.close();
    }));

    final deadline = DateTime.now().add(const Duration(seconds: 90));
    while (DateTime.now().isBefore(deadline)) {
      if (!identical(_proc, proc)) break;
      try {
        final r = await _gqlRaw('{ aboutServer { version } }');
        if (r['data'] != null) {
          _log('ready on 127.0.0.1:$port');
          return;
        }
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    proc.kill();
    _proc = null;
    _port = null;
    throw PlatformException(
      code: 'ENGINE',
      message: 'The manga engine did not start. See manga-engine/engine.log.',
    );
  }

  void dispose() {
    _proc?.kill();
    _proc = null;
    _http.close(force: true);
  }

  // ── GraphQL ────────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> _gqlRaw(String query) async {
    final req = await _http.postUrl(
      Uri.parse('http://127.0.0.1:$_port/api/graphql'),
    );
    req.headers.contentType = ContentType.json;
    req.add(utf8.encode(jsonEncode({'query': query})));
    final res = await req.close().timeout(const Duration(seconds: 120));
    final text = await utf8.decoder.bind(res).join();
    return jsonDecode(text) as Map<String, dynamic>;
  }

  /// Runs [query] and returns `data`; throws on GraphQL errors.
  Future<Map<String, dynamic>> _gql(String query) async {
    await ensureStarted();
    final r = await _gqlRaw(query);
    final errors = r['errors'];
    if (errors is List && errors.isNotEmpty) {
      final msg = '${(errors.first as Map)['message']}'.split('\n').first;
      throw PlatformException(code: 'ENGINE', message: msg);
    }
    return (r['data'] as Map).cast<String, dynamic>();
  }

  static String _q(String s) => jsonEncode(s); // a GraphQL string literal

  String get _base => 'http://127.0.0.1:$_port';

  // ── repos & install ────────────────────────────────────────────────────────

  List<String> _repoUrls() {
    final urls = <String>{_defaultRepo};
    if (Hive.isBoxOpen('mihon_repos')) {
      for (final v in Hive.box<String>('mihon_repos').values) {
        final u = v.trim();
        if (u.isEmpty) continue;
        // The app's repos point at index.pb / index.json; Suwayomi wants the
        // index.min.json that lives beside them.
        urls.add(u.replaceAll(RegExp(r'index(\.min)?\.(json|pb)$'), 'index.min.json'));
      }
    }
    return urls.toList();
  }

  Future<void> _applyRepos() async {
    if (_reposApplied) return;
    final list = _repoUrls().map(_q).join(', ');
    await _gql(
      'mutation { setSettings(input: { settings: { extensionRepos: [$list] } }) { settings { extensionRepos } } }',
    );
    _reposApplied = true;
  }

  Future<void> _install(String pkg) async {
    await _applyRepos();
    Object? last;
    for (var i = 0; i < 6; i++) {
      try {
        final d = await _gql(
          'mutation { updateExtension(input: { id: ${_q(pkg)}, patch: { install: true } }) { extension { pkgName isInstalled } } }',
        );
        final ext = (d['updateExtension'] as Map?)?['extension'] as Map?;
        if (ext != null && ext['isInstalled'] == true) {
          _log('installed $pkg');
          return;
        }
      } catch (e) {
        last = e;
      }
      // The store listing may not be loaded yet (or GitHub answered 403):
      // refresh it and try again.
      try {
        await _gql('mutation { fetchExtensions(input: {}) { extensions { pkgName } } }');
      } catch (e) {
        last = e;
      }
      await Future<void>.delayed(const Duration(seconds: 4));
    }
    _log('install $pkg failed: $last');
    throw PlatformException(
      code: 'LOAD',
      message: 'Could not install $pkg through the manga engine ($last)',
    );
  }

  // ── channel contract ───────────────────────────────────────────────────────

  Future<Object?> invoke(String method, Object? rawArgs) async {
    final a = (rawArgs is Map) ? rawArgs.cast<Object?, Object?>() : const {};
    switch (method) {
      case 'loadInstalled':
        await ensureStarted();
        return null;
      case 'installExtension':
        final apk = '${a['apkPath']}'.replaceAll('\\', '/');
        final name = apk.substring(apk.lastIndexOf('/') + 1);
        await _install(name.replaceAll(RegExp(r'\.apk$'), ''));
        return null;
      case 'listSources':
        return _listSources();
      case 'getPopular':
        return _browse('${a['sourceId']}', 'POPULAR', _page(a), null);
      case 'getLatest':
        return _browse('${a['sourceId']}', 'LATEST', _page(a), null);
      case 'search':
        final q = '${a['query'] ?? ''}'.trim();
        return _browse(
          '${a['sourceId']}',
          q.isEmpty ? 'POPULAR' : 'SEARCH',
          _page(a),
          q.isEmpty ? null : q,
        );
      case 'getDetails':
        return _details('${a['sourceId']}', '${a['url']}');
      case 'getChapters':
        return _chapters('${a['sourceId']}', '${a['url']}');
      case 'getPages':
        return _pages('${a['sourceId']}', '${a['url']}');
      case 'getImage':
        return _image('${a['url']}');
      case 'hasSourceSettings':
        return false;
      case 'readSourceSettings':
        return <Object?>[];
      case 'writeSourceSetting':
        return false;
      case 'getFilterList':
      case 'webUrl':
      case 'imageCookie':
      case 'clearHttpCache':
      case 'openSourceSettings':
      case 'solveCloudflare':
      case 'openSourceWebView':
        return null;
    }
    throw MissingPluginException('manga engine: $method');
  }

  int _page(Map a) => (a['page'] as num?)?.toInt() ?? 1;

  Future<String> _listSources() async {
    final d = await _gql(
      '{ sources { nodes { id name lang isNsfw homeUrl extension { pkgName versionName versionCode } } } }',
    );
    final nodes = ((d['sources'] as Map)['nodes'] as List).cast<Map>();
    final out = <Map<String, Object?>>[];
    for (final n in nodes) {
      final id = '${n['id']}';
      if (id == '0') continue; // Suwayomi's built-in "Local source"
      final ext = (n['extension'] as Map?) ?? const {};
      out.add({
        'id': int.parse(id),
        'name': n['name'],
        'lang': n['lang'],
        'nsfw': n['isNsfw'] == true,
        'pkg': ext['pkgName'] ?? '',
        'baseUrl': n['homeUrl'] ?? '',
        'headers': <String, String>{},
        'version': ext['versionName'] ?? '',
        'versionCode': ext['versionCode'] ?? 0,
      });
    }
    return jsonEncode(out);
  }

  String? _abs(Object? thumb) {
    final t = thumb as String?;
    if (t == null || t.isEmpty) return null;
    return t.startsWith('/') ? '$_base$t' : t;
  }

  Future<String> _browse(String sid, String type, int page, String? query) async {
    final queryArg = query == null ? '' : ', query: ${_q(query)}';
    final d = await _gql(
      'mutation { fetchSourceManga(input: { source: ${_q(sid)}, type: $type, page: $page$queryArg }) { mangas { id title thumbnailUrl url } } }',
    );
    final mangas = ((d['fetchSourceManga'] as Map)['mangas'] as List).cast<Map>();
    final out = <Map<String, Object?>>[];
    for (final m in mangas) {
      final url = '${m['url']}';
      _mangaIds['$sid|$url'] = (m['id'] as num).toInt();
      out.add({
        'url': url,
        'title': m['title'],
        'thumbnail_url': _abs(m['thumbnailUrl']),
      });
    }
    return jsonEncode(out);
  }

  Future<int> _mangaId(String sid, String url) async {
    final known = _mangaIds['$sid|$url'];
    if (known != null) return known;
    final d = await _gql(
      '{ mangas(filter: { sourceId: { equalTo: ${_q(sid)} }, url: { equalTo: ${_q(url)} } }) { nodes { id } } }',
    );
    final nodes = ((d['mangas'] as Map)['nodes'] as List);
    if (nodes.isEmpty) {
      throw PlatformException(code: 'NOT_FOUND', message: 'Unknown manga $url');
    }
    final id = ((nodes.first as Map)['id'] as num).toInt();
    _mangaIds['$sid|$url'] = id;
    return id;
  }

  static int _statusInt(Object? s) => switch ('$s') {
        'ONGOING' => 1,
        'COMPLETED' => 2,
        'LICENSED' => 3,
        'PUBLISHING_FINISHED' => 4,
        'CANCELLED' => 5,
        'ON_HIATUS' => 6,
        _ => 0,
      };

  Future<String> _details(String sid, String url) async {
    final id = await _mangaId(sid, url);
    final d = await _gql(
      'mutation { fetchManga(input: { id: $id }) { manga { title author artist description genre status thumbnailUrl } } }',
    );
    final m = (d['fetchManga'] as Map)['manga'] as Map;
    return jsonEncode({
      'url': url,
      'title': m['title'],
      'author': m['author'],
      'artist': m['artist'],
      'description': m['description'],
      'genre': ((m['genre'] as List?) ?? const []).join(', '),
      'status': _statusInt(m['status']),
      'thumbnail_url': _abs(m['thumbnailUrl']),
    });
  }

  Future<String> _chapters(String sid, String url) async {
    final id = await _mangaId(sid, url);
    final d = await _gql(
      'mutation { fetchChapters(input: { mangaId: $id }) { chapters { id name chapterNumber scanlator uploadDate url } } }',
    );
    final list = ((d['fetchChapters'] as Map)['chapters'] as List).cast<Map>();
    final out = <Map<String, Object?>>[];
    for (final c in list) {
      final curl = '${c['url']}';
      _chapterIds['$sid|$curl'] = (c['id'] as num).toInt();
      out.add({
        'url': curl,
        'name': c['name'],
        'date_upload': int.tryParse('${c['uploadDate']}') ?? 0,
        'chapter_number': (c['chapterNumber'] as num?)?.toDouble() ?? -1.0,
        'scanlator': c['scanlator'],
      });
    }
    return jsonEncode(out);
  }

  Future<String> _pages(String sid, String chapterUrl) async {
    var id = _chapterIds['$sid|$chapterUrl'];
    if (id == null) {
      final d = await _gql(
        '{ chapters(filter: { url: { equalTo: ${_q(chapterUrl)} } }) { nodes { id manga { sourceId } } } }',
      );
      for (final n in ((d['chapters'] as Map)['nodes'] as List).cast<Map>()) {
        if ('${(n['manga'] as Map?)?['sourceId']}' == sid) {
          id = (n['id'] as num).toInt();
          break;
        }
      }
      if (id == null) {
        throw PlatformException(code: 'NOT_FOUND', message: 'Unknown chapter $chapterUrl');
      }
      _chapterIds['$sid|$chapterUrl'] = id;
    }
    final d = await _gql(
      'mutation { fetchChapterPages(input: { chapterId: $id }) { pages } }',
    );
    final pages = ((d['fetchChapterPages'] as Map)['pages'] as List).cast<String>();
    return jsonEncode([
      for (var i = 0; i < pages.length; i++)
        {
          'index': i,
          'url': '',
          'imageUrl': pages[i].startsWith('/') ? '$_base${pages[i]}' : pages[i],
        },
    ]);
  }

  Future<Uint8List> _image(String url) async {
    final req = await _http.getUrl(Uri.parse(url));
    final res = await req.close().timeout(const Duration(seconds: 60));
    if (res.statusCode != 200) {
      throw PlatformException(code: 'IMAGE', message: 'HTTP ${res.statusCode}');
    }
    final bb = BytesBuilder(copy: false);
    await for (final chunk in res) {
      bb.add(chunk);
    }
    return bb.takeBytes();
  }
}

/// Drop-in for `MethodChannel('zangetsu/mihon')`: on Windows (with the engine
/// present) calls go to [MangaEngine]; everywhere else it is a plain channel,
/// so Android's behaviour is untouched.
class MangaChannel extends MethodChannel {
  const MangaChannel(super.name);

  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) async {
    if (!MangaEngine.isAvailable ||
        Platform.environment['FLUTTER_TEST'] == 'true') {
      return super.invokeMethod<T>(method, arguments);
    }
    final result = await MangaEngine.instance.invoke(method, arguments);
    return result as T?;
  }
}
