import 'package:dio/dio.dart';
import '../constants/app_constants.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Brain API client — bearer-token auth for mobile.
///
/// Flutter uses a stored access token (obtained via login or OAuth
/// sign-in); browsers use the HttpOnly session cookie instead.
class BrainClient {
  BrainClient._();
  static final BrainClient instance = BrainClient._();

  static const String defaultBaseUrl = AppConstants.brainApiUrl;
  static const String _tokenKey = 'brain_access_token';
  static const String _baseUrlKey = 'brain_base_url';

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
    ),
  );

  String? _token;
  String _baseUrl = defaultBaseUrl;

  String get baseUrl => _baseUrl;
  bool get hasToken => _token != null && _token!.isNotEmpty;

  /// Bearer token for streaming endpoints (SSE headers).
  String? get token => _token;

  Future<void>? _initFuture;

  /// Loads the persisted token/base URL exactly once. Request helpers
  /// await this so cold-start calls never race the SharedPreferences
  /// read (the first-frame providers otherwise send unauthenticated
  /// requests → transient DioException before the UI recovers).
  Future<void> init() => _initFuture ??= _initImpl();

  Future<void> _initImpl() async {
    final prefs = await SharedPreferences.getInstance();
    _token = prefs.getString(_tokenKey);
    _baseUrl = prefs.getString(_baseUrlKey) ?? defaultBaseUrl;
  }

  /// [persist] — false keeps the token in memory only (login without
  /// "remember this device"): the next cold start sees no stored
  /// credential and returns to the login screen.
  Future<void> setToken(String? token, {bool persist = true}) async {
    _token = token;
    final prefs = await SharedPreferences.getInstance();
    if (token == null || !persist) {
      await prefs.remove(_tokenKey);
    } else {
      await prefs.setString(_tokenKey, token);
    }
  }

  Future<void> setBaseUrl(String url) async {
    _baseUrl = url.endsWith('/') ? url.substring(0, url.length - 1) : url;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_baseUrlKey, _baseUrl);
  }

  Options get _opts => _options();

  /// Request options — [bearerToken] overrides the stored user token so a
  /// gateway can act with a device-scoped JWT (heartbeat/pairing-status);
  /// [headers] merges extras such as ``X-Pairing-Secret``.
  Options _options({String? bearerToken, Map<String, dynamic>? headers}) =>
      Options(
        headers: {
          'Accept': 'application/json',
          if (bearerToken != null)
            'Authorization': 'Bearer $bearerToken'
          else if (hasToken)
            'Authorization': 'Bearer $_token',
          ...?headers,
        },
      );

  String _api(String path) => '$_baseUrl/api$path';
  String _v1(String path) => '$_baseUrl/v1$path';

  Future<Map<String, dynamic>> getJson(
    String path, {
    Map<String, dynamic>? params,
    String? bearerToken,
    Map<String, dynamic>? headers,
    Duration? timeout,
  }) async {
    await init();
    final res = await _dio.get(
      _api(path),
      queryParameters: params,
      options: _options(bearerToken: bearerToken, headers: headers).copyWith(
        connectTimeout: timeout,
        sendTimeout: timeout,
        receiveTimeout: timeout,
      ),
    );
    return Map<String, dynamic>.from(res.data as Map);
  }

  /// GET a versioned v1 endpoint.
  Future<Map<String, dynamic>> getV1(
    String path, {
    Map<String, dynamic>? params,
  }) async {
    await init();
    final res = await _dio.get(
      _v1(path),
      queryParameters: params,
      options: _opts,
    );
    return Map<String, dynamic>.from(res.data as Map);
  }

  /// POST a versioned v1 endpoint.
  ///
  /// [timeout] overrides BOTH send/receive timeouts — LLM-backed
  /// calls (chat, transcribe) legitimately outlive the 30 s default.
  Future<Map<String, dynamic>> postV1(
    String path, {
    Map<String, dynamic>? body,
    Duration? timeout,
  }) async {
    await init();
    final opts = timeout == null
        ? _opts
        : _opts.copyWith(receiveTimeout: timeout, sendTimeout: timeout);
    final res = await _dio.post(
      _v1(path),
      data: body ?? {},
      options: opts,
    );
    return Map<String, dynamic>.from(res.data as Map);
  }

  /// PUT a legacy ``/api`` endpoint.
  Future<Map<String, dynamic>> putJson(
    String path, {
    Map<String, dynamic>? body,
  }) async {
    await init();
    final res = await _dio.put(
      _api(path),
      data: body ?? {},
      options: _opts,
    );
    return Map<String, dynamic>.from(res.data as Map);
  }

  /// DELETE a versioned v1 endpoint.
  Future<Map<String, dynamic>> deleteV1(String path) async {
    await init();
    final res = await _dio.delete(_v1(path), options: _opts);
    return res.data is Map
        ? Map<String, dynamic>.from(res.data as Map)
        : <String, dynamic>{};
  }

  /// Recent typed predictions for a device (v1 ``PredictionListV1``).
  Future<List<Map<String, dynamic>>> getDevicePredictions(
    String deviceId, {
    int limit = 50,
  }) async {
    final res = await getV1(
      '/devices/$deviceId/predictions',
      params: {'limit': limit},
    );
    final list = (res['predictions'] ?? const []) as List;
    return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  /// Cursor-paged real samples for one sensor (v1 ``StreamPageV1``).
  /// Returns ``{samples: [...], cursor: String?, state: String}``.
  Future<Map<String, dynamic>> streamSensor(
    String deviceId,
    String sensorId, {
    String? cursor,
  }) async {
    return getV1(
      '/devices/$deviceId/streams/$sensorId',
      params: {if (cursor != null) 'cursor': cursor},
    );
  }

  /// List a device's captures (v1 ``CaptureListV1``).
  Future<List<Map<String, dynamic>>> getDeviceCaptures(String deviceId) async {
    final res = await getV1('/devices/$deviceId/captures');
    final list = (res['captures'] ?? const []) as List;
    return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  /// Start a capture; returns the durable CaptureV1 (state ``requested``).
  Future<Map<String, dynamic>> startCapture(
    String deviceId, {
    List<String>? sensors,
  }) async {
    return postV1(
      '/devices/$deviceId/captures',
      body: {'sensors': sensors ?? []},
    );
  }

  /// Stop a capture by its durable id; returns ``{id, device_id, state}``.
  Future<Map<String, dynamic>> stopCapture(String captureId) async {
    return postV1('/captures/$captureId/stop');
  }

  Future<Map<String, dynamic>> postJson(
    String path, {
    Map<String, dynamic>? body,
    String? bearerToken,
    Map<String, dynamic>? headers,
  }) async {
    final res = await _dio.post(
      _api(path),
      data: body ?? {},
      options: _options(bearerToken: bearerToken, headers: headers),
    );
    return Map<String, dynamic>.from(res.data as Map);
  }

  // ── Watch (PineTime) gateway endpoints ───────────────────────────────────

  /// POST /api/device/pairing/start — begin pairing on the watch's behalf.
  /// The response carries ``code`` (user-facing) and ``pairing_secret``
  /// (gateway-held credential for /pairing/status).
  Future<Map<String, dynamic>> devicePairingStart({
    required String deviceId,
    required String deviceName,
    String deviceType = 'pinetime',
    Map<String, dynamic>? hardwareInfo,
  }) =>
      postJson(
        '/device/pairing/start',
        body: {
          'device_id': deviceId,
          'device_name': deviceName,
          'device_type': deviceType,
          if (hardwareInfo != null) 'hardware_info': hardwareInfo,
        },
      );

  /// GET /api/device/pairing/status — poll until the user claims the code.
  /// Returns ``access_token`` (device JWT) once paired.
  Future<Map<String, dynamic>> devicePairingStatus(
    String deviceId,
    String pairingSecret,
  ) =>
      getJson(
        '/device/pairing/status',
        params: {'device_id': deviceId},
        headers: {'X-Pairing-Secret': pairingSecret},
      );

  /// POST /api/device/heartbeat on behalf of the watch (device JWT).
  Future<Map<String, dynamic>> deviceHeartbeat(
    String deviceToken,
    Map<String, dynamic> body,
  ) =>
      postJson('/device/heartbeat', body: body, bearerToken: deviceToken);

  /// GET /api/device/list — all approved devices on the account.
  Future<List<Map<String, dynamic>>> listDevices({
    bool includeOffline = true,
  }) async {
    final res = await getJson(
      '/device/list',
      params: {'include_offline': includeOffline},
    );
    final list = (res['devices'] ?? const []) as List;
    return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  /// GET /api/device/{uuid}/live-chunks — current-minute chunks; each
  /// chunk's ``samples`` holds SensorSampleV1 maps (gps/prox/imu…).
  Future<Map<String, dynamic>> getLiveChunks(String deviceUuid) =>
      getJson('/device/$deviceUuid/live-chunks');

  /// POST /api/device/{uuid}/live-chunks — user-token auth (device tokens
  /// are rejected by get_current_user; the watch device belongs to the
  /// app's owner so the user token is both valid and required).
  Future<Map<String, dynamic>> uploadLiveChunk(
    String deviceUuid,
    Map<String, dynamic> payload,
  ) =>
      postJson('/device/$deviceUuid/live-chunks', body: payload);

  /// POST /api/device/{uuid}/commands — queue a command the gateway drains
  /// (watch_notify / watch_nav / watch_alert / ble_gatt_write …).
  Future<Map<String, dynamic>> queueDeviceCommand(
    String deviceUuid,
    String command, {
    Map<String, dynamic>? payload,
  }) =>
      postJson(
        '/device/$deviceUuid/commands',
        body: {'command': command, 'payload': payload ?? {}},
      );

  /// POST /api/device/{uuid}/commands/{id}/ack — acknowledge an executed
  /// command; accepts either the device JWT or the owner user token.
  Future<Map<String, dynamic>> ackDeviceCommand(
    String deviceUuid,
    int commandId,
    Map<String, dynamic> result, {
    String? bearerToken,
  }) =>
      postJson(
        '/device/$deviceUuid/commands/$commandId/ack',
        body: result,
        bearerToken: bearerToken,
      );

  Future<Map<String, dynamic>> postMultipart(
    String path,
    String field,
    String filename,
    List<int> bytes,
  ) async {
    final form = FormData.fromMap({
      field: MultipartFile.fromBytes(bytes, filename: filename),
    });
    final res = await _dio.post(_api(path), data: form, options: _opts);
    return Map<String, dynamic>.from(res.data as Map);
  }

  Future<void> delete(String path) async {
    await _dio.delete(_api(path), options: _opts);
  }

  /// Login with username/password; stores the returned token.
  Future<Map<String, dynamic>> login(
    String username,
    String password, {
    bool persist = true,
  }) async {
    final res = await _dio.post(
      '$_baseUrl/api/token',
      data: {'username': username, 'password': password},
      options: Options(headers: {'Accept': 'application/json'}),
    );
    final data = Map<String, dynamic>.from(res.data as Map);
    final token = data['access_token'] as String?;
    if (token == null) {
      throw DioException(
        requestOptions: res.requestOptions,
        error: 'No access_token in response',
      );
    }
    await setToken(token, persist: persist);
    return data;
  }

  Future<void> logout() async {
    try {
      await postJson('/logout');
    } catch (_) {/* best-effort */}
    await setToken(null);
  }
}
