import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

/// Réglages saisis par l'utilisateur. Les secrets restent sur le téléphone
/// (stockage chiffré), rien n'est codé en dur dans l'app ni dans l'agent.
class Settings {
  final String agentUrl; // ex: http://192.168.1.20:8787 (stats système)
  final String agentToken;
  final String jellyfinUrl; // ex: http://192.168.1.20:8096
  final String jellyfinKey;
  const Settings({
    this.agentUrl = '',
    this.agentToken = '',
    this.jellyfinUrl = '',
    this.jellyfinKey = '',
  });

  bool get hasAgent => agentUrl.isNotEmpty;
  bool get hasJellyfin => jellyfinUrl.isNotEmpty && jellyfinKey.isNotEmpty;
  bool get isSet => hasAgent || hasJellyfin;

  static const _store = FlutterSecureStorage();

  static Future<Settings> load() async {
    Future<String> r(String k) async => await _store.read(key: k) ?? '';
    return Settings(
      agentUrl: await r('agentUrl'),
      agentToken: await r('agentToken'),
      jellyfinUrl: await r('jellyfinUrl'),
      jellyfinKey: await r('jellyfinKey'),
    );
  }

  Future<void> save() async {
    await _store.write(key: 'agentUrl', value: agentUrl);
    await _store.write(key: 'agentToken', value: agentToken);
    await _store.write(key: 'jellyfinUrl', value: jellyfinUrl);
    await _store.write(key: 'jellyfinKey', value: jellyfinKey);
  }

  /// Ajoute http:// si absent et retire les "/" finaux.
  static String normalizeUrl(String u) {
    u = u.trim();
    if (u.isEmpty) return '';
    if (!u.startsWith('http')) u = 'http://$u';
    return u.replaceAll(RegExp(r'/+$'), '');
  }
}

class Disk {
  final String name, path, device, fstype;
  final int total, used;
  final double percent;
  Disk(Map<String, dynamic> j)
      : name = j['name'],
        path = j['path'] ?? '',
        device = j['device'] ?? '',
        fstype = j['fstype'] ?? '',
        total = j['total'],
        used = j['used'],
        percent = (j['percent'] as num).toDouble();
}

class SystemStats {
  final double cpu;
  final double? temp;
  final List<double> cores;
  final int ramUsed, ramTotal;
  final double ramPercent;
  final List<Disk> disks;
  final double downBps, upBps;
  final List<double> downHistory, upHistory; // octets/s, un point toutes les netIntervalS secondes
  final int netIntervalS;
  final int uptimeS;

  SystemStats(Map<String, dynamic> j)
      : cpu = (j['cpu_percent'] as num).toDouble(),
        temp = (j['cpu_temp'] as num?)?.toDouble(),
        cores = [for (final c in j['cpu_per_core']) (c as num).toDouble()],
        ramUsed = j['ram']['used'],
        ramTotal = j['ram']['total'],
        ramPercent = (j['ram']['percent'] as num).toDouble(),
        disks = [for (final d in j['disks']) Disk(d)],
        downBps = (j['net']['down_bps'] as num).toDouble(),
        upBps = (j['net']['up_bps'] as num).toDouble(),
        downHistory = [for (final v in j['net_history']['down']) (v as num).toDouble()],
        upHistory = [for (final v in j['net_history']['up']) (v as num).toDouble()],
        netIntervalS = j['net_history']['interval_s'],
        uptimeS = j['uptime_s'];
}

/// Programme ou conteneur Docker, avec la RAM qu'il utilise.
class ProcUsage {
  final String name, kind; // kind : container | process
  final int ram, count;
  final double percent;
  ProcUsage(Map<String, dynamic> j)
      : name = j['name'],
        kind = j['kind'],
        ram = j['ram'],
        count = j['count'],
        percent = (j['percent'] as num).toDouble();
}

class PlaySession {
  final String id, itemId; // id de session Jellyfin, id du média
  final String user, device, title;
  final String? episodeTitle, imageId;
  final DateTime fetchedAt = DateTime.now();
  final int? season, episode;
  final int positionS, runtimeS;
  final bool paused, transcoding;

  PlaySession._({
    required this.id,
    required this.itemId,
    required this.user,
    required this.device,
    required this.title,
    this.episodeTitle,
    this.imageId,
    this.season,
    this.episode,
    required this.positionS,
    required this.runtimeS,
    required this.paused,
    required this.transcoding,
  });

  /// Construit une session depuis un objet de GET /Sessions (null si rien n'est lu).
  static PlaySession? fromJellyfin(Map<String, dynamic> j) {
    final item = j['NowPlayingItem'] as Map<String, dynamic>?;
    if (item == null) return null;
    final ps = (j['PlayState'] as Map<String, dynamic>?) ?? {};
    final isEpisode = item['Type'] == 'Episode';
    final tc = j['TranscodingInfo'] as Map<String, dynamic>?;
    return PlaySession._(
      id: j['Id'],
      itemId: item['Id'],
      user: j['UserName'] ?? '?',
      device: j['DeviceName'] ?? '',
      title: (isEpisode ? item['SeriesName'] : item['Name']) ?? '',
      episodeTitle: isEpisode ? item['Name'] : null,
      // Affiche de la série pour un épisode, sinon celle du film
      imageId: isEpisode ? item['SeriesId'] : item['Id'],
      season: isEpisode ? item['ParentIndexNumber'] : null,
      episode: isEpisode ? item['IndexNumber'] : null,
      positionS: ((ps['PositionTicks'] ?? 0) as int) ~/ 10000000,
      runtimeS: ((item['RunTimeTicks'] ?? 0) as int) ~/ 10000000,
      paused: ps['IsPaused'] == true,
      transcoding: tc != null && tc['IsVideoDirect'] == false,
    );
  }

  /// "S07E08 · Titre de l'épisode" (vide pour un film)
  String get subtitle => season != null
      ? 'S${season.toString().padLeft(2, '0')}E${episode.toString().padLeft(2, '0')}'
          '${episodeTitle != null ? ' · $episodeTitle' : ''}'
      : '';

  /// Position estimée à l'instant [now] : elle avance d'une seconde par seconde
  /// tant que la lecture n'est pas en pause, entre deux interrogations de Jellyfin.
  int livePositionS(DateTime now) {
    if (paused) return positionS;
    final p = positionS + now.difference(fetchedAt).inSeconds;
    return runtimeS > 0 && p > runtimeS ? runtimeS : p;
  }

  double progressAt(DateTime now) =>
      runtimeS > 0 ? (livePositionS(now) / runtimeS).clamp(0, 1).toDouble() : 0;

  /// Même média, même état, même position rapportée : on garde l'ancien objet
  /// pour que le compteur continue sans saut.
  bool sameAs(PlaySession o) =>
      id == o.id && itemId == o.itemId && paused == o.paused && positionS == o.positionS;
}

class Device {
  final String id, name, kind; // kind : light | plug
  final bool online;
  final bool on;
  final int? brightness; // 1..100
  final String? color; // #rrggbb
  final String? error;
  final String? mode; // colour | white | ...
  final int? timer; // secondes restantes du minuteur (prises)
  final List<String> caps; // fonctions disponibles : color, white, timer
  final DateTime fetchedAt = DateTime.now();
  Device(Map<String, dynamic> j)
      : id = j['id'],
        name = j['name'],
        kind = j['kind'],
        online = j['online'] == true,
        on = j['on'] == true,
        brightness = j['brightness'],
        color = j['color'],
        error = j['error'],
        mode = j['mode'],
        timer = j['timer'],
        caps = [for (final c in (j['caps'] ?? []) as List) c.toString()];
  bool get isLight => kind == 'light';

  /// Secondes restantes du minuteur à l'instant [now] (0 si aucun).
  int timerLeft(DateTime now) {
    if (timer == null) return 0;
    final left = timer! - now.difference(fetchedAt).inSeconds;
    return left > 0 ? left : 0;
  }
}

/// Contrôleur Surplife / Magic Home trouvé sur le réseau local.
class LocalLight {
  final String mac, ip, model;
  final bool added;
  LocalLight(Map<String, dynamic> j)
      : mac = j['mac'],
        ip = j['ip'],
        model = j['model'] ?? '',
        added = j['added'] == true;
}

/// Appareil trouvé dans le compte Tuya, proposé à l'ajout.
class FoundDevice {
  final String id, name, kind, ip;
  final bool added;
  FoundDevice(Map<String, dynamic> j)
      : id = j['id'],
        name = j['name'],
        kind = j['kind'],
        ip = j['ip'] ?? '',
        added = j['added'] == true;
}

class ApiException implements Exception {
  final String message;
  ApiException(this.message);
  @override
  String toString() => message;
}

class Api {
  final Settings s;
  Api(this.s);

  static const _timeout = Duration(seconds: 6);

  Map<String, String> get jellyfinHeaders => {'X-Emby-Token': s.jellyfinKey};

  String jellyfinImageUrl(String id) =>
      '${s.jellyfinUrl}/Items/$id/Images/Primary?maxWidth=400&quality=85';

  Future<dynamic> _get(String url, Map<String, String> headers) async {
    try {
      final r = await http.get(Uri.parse(url), headers: headers).timeout(_timeout);
      if (r.statusCode == 401) throw ApiException('Clé ou token refusé (401)');
      if (r.statusCode != 200) throw ApiException('Erreur HTTP ${r.statusCode}');
      return jsonDecode(utf8.decode(r.bodyBytes));
    } on ApiException {
      rethrow;
    } catch (e) {
      throw ApiException('Injoignable : $url');
    }
  }

  Future<void> _post(String url, Map<String, String> headers, Object body) async {
    try {
      final r = await http
          .post(Uri.parse(url), headers: {...headers, 'Content-Type': 'application/json'}, body: jsonEncode(body))
          .timeout(const Duration(seconds: 10));
      if (r.statusCode == 401) throw ApiException('Clé ou token refusé (401)');
      if (r.statusCode >= 300) {
        var detail = '';
        try {
          detail = (jsonDecode(utf8.decode(r.bodyBytes)) as Map)['detail']?.toString() ?? '';
        } catch (_) {}
        throw ApiException('Erreur HTTP ${r.statusCode} $detail'.trim());
      }
    } on ApiException {
      rethrow;
    } catch (e) {
      throw ApiException('Injoignable : $url');
    }
  }

  Map<String, String> get _agentHeaders =>
      s.agentToken.isEmpty ? {} : {'Authorization': 'Bearer ${s.agentToken}'};

  /// Affiche un message à l'écran de la session (comme le fait Jellyfin).
  Future<void> sendMessage(String sessionId, String header, String text, int timeoutMs) =>
      _post('${s.jellyfinUrl}/Sessions/$sessionId/Message', jellyfinHeaders,
          {'Header': header, 'Text': text, 'TimeoutMs': timeoutMs});

  Future<List<Device>> devices() async => [
        for (final j in await _get('${s.agentUrl}/api/devices', _agentHeaders) as List)
          Device(j as Map<String, dynamic>)
      ];

  Future<void> setPower(String id, bool on) =>
      _post('${s.agentUrl}/api/devices/$id/power', _agentHeaders, {'on': on});

  Future<void> setBrightness(String id, int value) =>
      _post('${s.agentUrl}/api/devices/$id/brightness', _agentHeaders, {'value': value});

  Future<void> setColor(String id, String hex) =>
      _post('${s.agentUrl}/api/devices/$id/color', _agentHeaders, {'hex': hex});

  Future<void> setWhite(String id, int temp, int brightness) => _post(
      '${s.agentUrl}/api/devices/$id/white', _agentHeaders, {'temp': temp, 'brightness': brightness});

  /// Compte à rebours de la prise ; 0 annule.
  Future<void> setTimer(String id, int seconds) =>
      _post('${s.agentUrl}/api/devices/$id/timer', _agentHeaders, {'seconds': seconds});

  Future<void> removeDevice(String id) async {
    try {
      final r = await http
          .delete(Uri.parse('${s.agentUrl}/api/devices/$id'), headers: _agentHeaders)
          .timeout(const Duration(seconds: 10));
      if (r.statusCode >= 300) throw ApiException('Erreur HTTP ${r.statusCode}');
    } on ApiException {
      rethrow;
    } catch (e) {
      throw ApiException('Injoignable : ${s.agentUrl}');
    }
  }

  /// Interroge le compte Tuya IoT (les identifiants ne sont ni stockés ni conservés par l'agent).
  Future<List<FoundDevice>> importFromTuya(
      String accessId, String secret, String region, String deviceId) async {
    final r = await http
        .post(Uri.parse('${s.agentUrl}/api/devices/import'),
            headers: {..._agentHeaders, 'Content-Type': 'application/json'},
            body: jsonEncode({'access_id': accessId, 'secret': secret, 'region': region, 'device_id': deviceId}))
        .timeout(const Duration(seconds: 60));
    final body = jsonDecode(utf8.decode(r.bodyBytes));
    if (r.statusCode != 200) {
      throw ApiException(body is Map ? (body['detail'] ?? 'Erreur ${r.statusCode}').toString() : 'Erreur ${r.statusCode}');
    }
    return [for (final j in body as List) FoundDevice(j as Map<String, dynamic>)];
  }

  Future<List<LocalLight>> scanLocal() async => [
        for (final j in await _get('${s.agentUrl}/api/devices/scan-local', _agentHeaders) as List)
          LocalLight(j as Map<String, dynamic>)
      ];

  Future<void> addLocal(LocalLight l, String name) => _post(
      '${s.agentUrl}/api/devices/add-local', _agentHeaders, {'mac': l.mac, 'ip': l.ip, 'name': name});

  Future<void> addDevices(List<String> ids) =>
      _post('${s.agentUrl}/api/devices/add', _agentHeaders, {'ids': ids});

  Future<List<ProcUsage>> processes() async => [
        for (final j in await _get('${s.agentUrl}/api/processes?limit=8', _agentHeaders) as List)
          ProcUsage(j as Map<String, dynamic>)
      ];

  Future<SystemStats> system() async => SystemStats(await _get(
      '${s.agentUrl}/api/system', _agentHeaders));

  Future<List<PlaySession>> sessions() async {
    final list = await _get(
        '${s.jellyfinUrl}/Sessions?activeWithinSeconds=960', jellyfinHeaders) as List;
    return [
      for (final j in list)
        if (PlaySession.fromJellyfin(j as Map<String, dynamic>) case final p?) p
    ];
  }

  /// Utilisés par le bouton « Tester » des réglages.
  static Future<String?> testAgent(String url, String token) async {
    try {
      await Api(Settings(agentUrl: url, agentToken: token)).system();
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  static Future<String?> testJellyfin(String url, String key) async {
    try {
      await Api(Settings(jellyfinUrl: url, jellyfinKey: key)).sessions();
      return null;
    } catch (e) {
      return e.toString();
    }
  }
}
