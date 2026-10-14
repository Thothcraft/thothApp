import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Persisted record for one paired PineBuds set — same shape as
/// `WatchRecord`: the buds own a first-class Brain device row;
/// [deviceToken] feeds heartbeats, live-chunks go out under the app
/// user's bearer token.
class EarbudsRecord {
  const EarbudsRecord({
    required this.bleId,
    required this.deviceUuid,
    this.name,
    this.deviceToken,
    this.firmwareVersion,
  });

  final String bleId;
  final String deviceUuid;
  final String? name;
  final String? deviceToken;
  final String? firmwareVersion;

  EarbudsRecord copyWith({
    String? name,
    String? deviceToken,
    String? firmwareVersion,
  }) =>
      EarbudsRecord(
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

  static EarbudsRecord fromJson(Map<String, dynamic> j) => EarbudsRecord(
        bleId: j['ble_id'] as String,
        deviceUuid: j['device_uuid'] as String,
        name: j['name'] as String?,
        deviceToken: j['device_token'] as String?,
        firmwareVersion: j['firmware_version'] as String?,
      );
}

class EarbudsStore {
  EarbudsStore._();
  static final EarbudsStore instance = EarbudsStore._();

  static const _key = 'pinebuds_devices';
  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  Future<List<EarbudsRecord>> load() async {
    final raw = await _storage.read(key: _key);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = json.decode(raw) as List;
      return list
          .map((e) => EarbudsRecord.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> save(List<EarbudsRecord> devices) => _storage.write(
      key: _key,
      value: json.encode(devices.map((d) => d.toJson()).toList()));

  Future<void> upsert(EarbudsRecord record) async {
    final all = (await load()).toList();
    final i = all.indexWhere((d) => d.bleId == record.bleId);
    if (i >= 0) {
      all[i] = record;
    } else {
      all.add(record);
    }
    await save(all);
  }

  Future<void> remove(String bleId) async {
    final all = (await load()).toList()
      ..removeWhere((d) => d.bleId == bleId);
    await save(all);
  }
}
