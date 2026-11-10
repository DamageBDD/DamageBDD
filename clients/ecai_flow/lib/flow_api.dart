import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';

typedef Json = Map<String, dynamic>;
class FlowException implements Exception {
  final String code;
  final int status;
  const FlowException(this.code, [this.status = 0]);
  @override String toString() => code;
}
String _stable(dynamic value) {
  if (value is List) return '[${value.map(_stable).join(',')}]';
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return '{${keys.map((k) => '${jsonEncode(k)}:${_stable(value[k])}').join(',')}}';
  }
  return jsonEncode(value);
}
bool verifyEnvelope(Json envelope, [String digestField = 'receipt_sha256']) {
  try {
    final text = envelope['payload_json'] as String;
    if (sha256.convert(utf8.encode(text)).toString() != envelope[digestField]) return false;
    final payload = jsonDecode(text) as Json;
    return payload.entries.every((e) => _stable(e.value) == _stable(envelope[e.key]));
  } catch (_) { return false; }
}
class Bundle {
  final Json data;
  const Bundle(this.data);
  String get id => data['id'] as String;
  String get title => data['title'] as String;
  String get mission => data['mission'] as String;
  String get digest => data['bundle_sha256'] as String;
  String text(String key) => data[key] as String;
  List<String> get limitations => (data['limitations'] as List).cast<String>();
}
class Run {
  final Json data;
  const Run(this.data);
  String get id => data['run_id'] as String;
  String get digest => data['run_sha256'] as String;
  bool get passed => data['all_candidate_passed'] == true;
  List<Json> get checks => (data['checks'] as List).cast<Json>();
}
class Receipt {
  final Json data;
  const Receipt(this.data);
  String get id => data['receipt_id'] as String;
  String get kind => data['kind'] as String;
  String get mission => data['mission'] as String;
  bool get valid => verifyEnvelope(data);
  String get exportJson => const JsonEncoder.withIndent('  ').convert(data);
}
class Session {
  final Json data;
  const Session(this.data);
  int get count => data['contribution_count'] as int;
  int get budget => data['budget'] as int;
  bool get complete => data['complete'] == true;
  List<Receipt> get receipts => (data['receipts'] as List).map((r) => Receipt(r as Json)).toList();
  bool has(String missionId, String kind) => receipts.any((r) => r.data['mission_id'] == missionId && r.kind == kind);
}
abstract class FlowRepository {
  Future<List<Bundle>> loadBundles();
  Future<Session> startSession(int budget);
  Future<Run> replay(Bundle bundle);
  Future<Session> contribute(Bundle bundle, String kind, String note, {Json? scenario, Run? run, bool acknowledge = false});
  void close();
}
/// Native-only transport. Tokens are in memory, never URLs, logs or preferences.
class FlowApi implements FlowRepository {
  final Uri base;
  final HttpClient _http;
  String _token = '';
  final Map<String, String> _pending = {};
  FlowApi(String url, {bool allowLocalHttp = false, HttpClient? client})
      : base = Uri.parse(url), _http = client ?? HttpClient() {
    final local = ['localhost','127.0.0.1','::1','10.0.2.2'].contains(base.host);
    if (!base.hasAuthority || base.userInfo.isNotEmpty || base.hasQuery || base.hasFragment ||
        !(base.scheme == 'https' || allowLocalHttp && local && base.scheme == 'http')) {
      _http.close(force: true);
      throw const FlowException('Use HTTPS, or an explicitly allowed local development URL.');
    }
    _http.connectionTimeout = const Duration(seconds: 10);
  }
  String _newKey() {
    final random = Random.secure();
    return List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }
  Future<Json> _request(String path, [Json? body]) async {
    final keyed = body != null && path != '/sessions';
    final fingerprint = '$path:${jsonEncode(body)}';
    final key = keyed ? _pending.putIfAbsent(fingerprint, _newKey) : null;
    final uri = Uri.parse('${base.toString().replaceFirst(RegExp(r'/$'), '')}$path');
    for (var attempt = 0; attempt < (keyed ? 2 : 1); attempt++) {
      HttpClientRequest? request;
      try {
        request = await _http.openUrl(body == null ? 'GET' : 'POST', uri).timeout(const Duration(seconds: 12));
        request.followRedirects = false; // Never forward a bearer to a redirect destination.
        request.headers.set(HttpHeaders.acceptHeader, 'application/json');
        if (_token.isNotEmpty) request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_token');
        if (key != null) request.headers.set('Idempotency-Key', key);
        if (body != null) {
          request.headers.contentType = ContentType.json;
          request.add(utf8.encode(jsonEncode(body)));
        }
        final response = await request.close().timeout(const Duration(seconds: 12));
        final bytes = <int>[];
        await for (final chunk in response.timeout(const Duration(seconds: 12))) {
          bytes.addAll(chunk);
          if (bytes.length > 1048576) throw const FlowException('response_too_large');
        }
        final decoded = jsonDecode(utf8.decode(bytes)) as Json;
        if (response.statusCode != 200 || decoded['ok'] != true) {
          if (response.statusCode < 500) _pending.remove(fingerprint);
          if (response.statusCode == 401) _token = '';
          throw FlowException(decoded['error'] as String? ?? 'request_failed', response.statusCode);
        }
        _pending.remove(fingerprint);
        return decoded['data'] as Json;
      } on FlowException { rethrow; }
      on Object catch (_) {
        request?.abort();
        if (!keyed || attempt == 1) throw const FlowException('connection_failed');
      }
    }
    throw const FlowException('connection_failed');
  }
  @override Future<List<Bundle>> loadBundles() async {
    final index = await _request('/catalog');
    final entries = (index['missions'] as List).cast<Json>();
    if (entries.length > 100) throw const FlowException('catalog_too_large');
    return Future.wait(entries.map((e) async {
      final id = e['id'] as String;
      if (!RegExp(r'^[a-z0-9-]+$').hasMatch(id)) throw const FlowException('invalid_mission_id');
      return Bundle(await _request('/missions/$id'));
    }));
  }
  @override Future<Session> startSession(int budget) async {
    final data = await _request('/sessions', {'budget': budget});
    _token = data['token'] as String;
    return Session(data);
  }
  @override Future<Run> replay(Bundle bundle) async {
    final result = await _request('/missions/${bundle.id}/run', {'bundle_sha256':bundle.digest});
    if (!verifyEnvelope(result, 'run_sha256')) throw const FlowException('run_integrity_failed');
    return Run(result);
  }
  @override Future<Session> contribute(Bundle bundle, String kind, String note,
      {Json? scenario, Run? run, bool acknowledge = false}) async {
    final body = <String,dynamic>{'kind':kind,'bundle_sha256':bundle.digest,'note':note,
      if (scenario != null) 'scenario':scenario,
      if (kind == 'practice_approve') ...{'run_id':run?.id,'run_sha256':run?.digest,'acknowledge_scope':acknowledge}};
    final result = await _request('/missions/${bundle.id}/contributions', body);
    if (!verifyEnvelope(result['receipt'] as Json)) throw const FlowException('receipt_integrity_failed');
    return Session(result['session'] as Json);
  }
  @override void close() => _http.close(force: true);
}
