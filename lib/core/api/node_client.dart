import 'package:dio/dio.dart';
import 'brain_client.dart';

/// Node API via Brain's WS relay (plans/CONTRACT.md §2/§5).
///
/// Mobile never talks to the node directly: every call posts
/// `{method, path, body}` to `POST /v1/nodes/{id}/api`; Brain forwards an
/// `api_request` frame over the node's tunnel and returns the
/// `api_response` body verbatim (status preserved).
class NodeClient {
  NodeClient._();
  static final NodeClient instance = NodeClient._();

  BrainClient get _brain => BrainClient.instance;

  /// Relay a single node call. Throws [NodeRelayException] when Brain
  /// reports the node has no tunnel (503) or the request times out (504).
  Future<dynamic> call(
    String deviceId,
    String method,
    String path, {
    Object? body,
  }) async {
    try {
      final res = await _brain.postV1('/nodes/$deviceId/api', body: {
        'method': method.toUpperCase(),
        'path': path.startsWith('/') ? path : '/$path',
        if (body != null) 'body': body,
      },);
      return res;
    } on DioException catch (e) {
      final status = e.response?.statusCode ?? 0;
      final detail = e.response?.data is Map
          ? (e.response?.data['detail'] ?? e.response?.data['error'])
          : e.message;
      throw NodeRelayException(status, '$detail');
    }
  }

  /// GET a node path; returns the decoded JSON body (Map/List/scalar).
  Future<dynamic> get(String deviceId, String path) =>
      call(deviceId, 'GET', path);

  Future<dynamic> post(String deviceId, String path, {Object? body}) =>
      call(deviceId, 'POST', path, body: body);

  Future<dynamic> put(String deviceId, String path, {Object? body}) =>
      call(deviceId, 'PUT', path, body: body);

  Future<dynamic> delete(String deviceId, String path) =>
      call(deviceId, 'DELETE', path);

  Future<Map<String, dynamic>> getMap(String deviceId, String path) async {
    final res = await get(deviceId, path);
    return res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};
  }

  // ---- typed helpers -------------------------------------------------

  Future<Map<String, dynamic>> status(String deviceId) =>
      getMap(deviceId, '/api/status');

  Future<List<Map<String, dynamic>>> sensors(String deviceId) async {
    final res = await getMap(deviceId, '/api/sensors');
    return (res['sensors'] as List? ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  Future<List<Map<String, dynamic>>> captures(String deviceId) async {
    final res = await getMap(deviceId, '/api/captures');
    return (res['captures'] as List? ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  Future<List<Map<String, dynamic>>> automations(String deviceId) async {
    final res = await getMap(deviceId, '/api/automations');
    return (res['automations'] as List? ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  Future<Map<String, dynamic>> metadata(String deviceId) =>
      getMap(deviceId, '/api/v1/metadata');

  /// Cached room/v1 doc served by Brain — `{room: {...}|null, cached}`.
  Future<Map<String, dynamic>> room(String deviceId) =>
      _brain.getV1('/nodes/$deviceId/room');

  /// Latest events for a device (notification feed; CONTRACT §6).
  /// Pass [since] (event id) for incremental polling.
  Future<List<Map<String, dynamic>>> events(String deviceId,
      {int limit = 50, String? since,}) async {
    final res = await _brain.getV1('/events', params: {
      'device_id': deviceId,
      'limit': limit,
      if (since != null) 'since': since,
    },);
    return (res['events'] as List? ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  Future<void> toggleAutomation(String deviceId, String automationId,
          {required bool enabled,}) =>
      post(deviceId, '/api/automations/$automationId', body: {
        'enabled': enabled,
      },);

  Future<void> startCapture(String deviceId) =>
      post(deviceId, '/api/captures/start', body: const {});

  Future<void> stopCapture(String deviceId, String captureId) =>
      post(deviceId, '/api/captures/stop', body: {'capture_id': captureId});

  // ---- node Wi-Fi (first-time setup) -----------------------------------

  /// Provisioning state + link info — `{state, wifi:{ssid,ip,…}, …}`.
  Future<Map<String, dynamic>> netStatus(String deviceId) =>
      getMap(deviceId, '/api/v1/net');

  /// Visible Wi-Fi networks — `{ssid, signal, security}` list.
  Future<List<Map<String, dynamic>>> netScan(String deviceId) async {
    final res = await getMap(deviceId, '/api/v1/net/scan');
    return (res['networks'] as List? ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  /// Hand SSID/PSK to the node — it joins that network (this Pi's Wi-Fi,
  /// not the phone's). The request is queued on the node's provisioning
  /// worker; poll [netStatus] for the outcome.
  Future<dynamic> netConnect(String deviceId, String ssid,
          {String psk = '', bool hidden = false}) =>
      post(deviceId, '/api/v1/net',
          body: {'ssid': ssid, 'psk': psk, 'hidden': hidden});

  /// Drop the node's Wi-Fi link — re-engages its BLE/AP commissioning
  /// surface (first-time setup).
  Future<dynamic> netDisconnect(String deviceId) =>
      post(deviceId, '/api/v1/net/disconnect');

  // ---- attached ESP32 (thoth_csi) boards ------------------------------

  /// Per-board state reported on the serial line — `{boards: [{name,
  /// mac, role, ssid, ip, connected, serial_port, sensor_id}]}`.
  Future<Map<String, dynamic>> esp32Status(String deviceId) =>
      getMap(deviceId, '/api/v1/esp32');

  /// Push Wi-Fi creds to the attached ESP32(s) — written to their
  /// serial consoles; the boards persist, reboot and join the AP.
  /// Independent of whether the node itself is being provisioned.
  Future<dynamic> esp32NetConnect(String deviceId, String ssid,
          {String psk = ''}) =>
      post(deviceId, '/api/v1/esp32/net',
          body: {'ssid': ssid, 'psk': psk},);

  /// Whitelist-checked console command to the attached ESP32(s) —
  /// `ping=<hz>` (0–200 CSI stimulus), `sweep=0|1`, `role=`,
  /// `chans=`, `name=`, or a `…?` query. Applied live, no reboot.
  Future<dynamic> esp32Cmd(String deviceId, String cmd) =>
      post(deviceId, '/api/v1/esp32/cmd', body: {'cmd': cmd},);
}

class NodeRelayException implements Exception {
  NodeRelayException(this.statusCode, this.message);
  final int statusCode;
  final String message;

  bool get offline => statusCode == 503;

  @override
  String toString() => 'NodeRelayException($statusCode): $message';
}
