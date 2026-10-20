import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Persisted record for one paired PineTime.
///
/// The watch owns a first-class Brain device row; [deviceToken] is the
/// device-scoped JWT returned by ``GET /device/pairing/status`` and is used
/// for heartbeats only — ``live-chunks`` and ``commands`` go out under the
/// app user's bearer token (device tokens are rejected by user endpoints).
class WatchRecord {
  const WatchRecord({
    required this.bleId, // platform BLE id (MAC on Android)
    required this.deviceUuid, // Brain device_uuid for the watch
    this.name,
    this.deviceToken,
    this.firmwareVersion,
  });

  final String bleId;
  final String deviceUuid;
  final String? name;
  final String? deviceToken;
  final String? firmwareVersion;

  WatchRecord copyWith({
    String? name,
    String? deviceToken,
    String? firmwareVersion,
  }) =>
      WatchRecord(
        bleId: bleId,
        deviceUuid: deviceUuid,
        name: name ?? this.name,
        deviceToken: deviceToken ?? this.deviceToken,
        firmwareVersion: firmwareVersion ?? this.firmwareVersion,
      );

  Map<String, dynamic> toJson() => {
        'ble_id': bleId,
        'device_uuid': deviceUuid,
        'name': name,
        'device_token': deviceToken,
        'firmware_version': firmwareVersion,
      };

  static WatchRecord fromJson(Map<String, dynamic> j) => WatchRecord(
        bleId: j['ble_id'] as String,
        deviceUuid: j['device_uuid'] as String,
        name: j['name'] as String?,
        deviceToken: j['device_token'] as String?,
        firmwareVersion: j['firmware_version'] as String?,
      );
}

/// Secure store for paired watches — secrets never hit SharedPreferences.
class WatchStore {
  WatchStore._();
  static final WatchStore instance = WatchStore._();

  static const _key = 'pinetime_watches';
  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  Future<List<WatchRecord>> load() async {
    final raw = await _storage.read(key: _key);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = json.decode(raw) as List;
      return list
          .map((e) => WatchRecord.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> save(List<WatchRecord> watches) =>
      _storage.write(key: _key, value: json.encode(watches.map((w) => w.toJson()).toList()));

  /// Load-modify-save is serialized — adopt + deferred Brain pairing
  /// upsert concurrently, and an interleaved read would silently drop
  /// the other record (a second watch vanishing from the list).
  Future _writeTail = Future.value();
  Future<void> _mutate(Future<void> Function(List<WatchRecord>) fn) {
    final next = _writeTail.then((_) async {
      final all = (await load()).toList();
      await fn(all);
      await save(all);
    });
    _writeTail = next.catchError((_) {});
    return next;
  }

  Future<void> upsert(WatchRecord record) => _mutate((all) async {
        final i = all.indexWhere((w) => w.bleId == record.bleId);
        if (i >= 0) {
          all[i] = record;
        } else {
          all.add(record);
        }
      });

  Future<void> remove(String bleId) =>
      _mutate((all) async => all.removeWhere((w) => w.bleId == bleId));
}
