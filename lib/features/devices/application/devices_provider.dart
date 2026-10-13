import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/brain_client.dart';

class ThothDevice {
  const ThothDevice({
    required this.uuid,
    required this.name,
    required this.online,
    this.deviceType,
    this.batteryLevel,
    this.lastSeen,
    this.hardwareInfo,
  });

  final String uuid;
  final String name;
  final bool online;
  final String? deviceType;
  final int? batteryLevel;
  final String? lastSeen;

  /// Raw ``hardware_info`` map (sensors/actuators/local_api/activity)
  /// — refreshed by the node heartbeat.
  final Map<String, dynamic>? hardwareInfo;

  /// ``hardware_info.activity`` — the node's live "what am I doing"
  /// snapshot: mode, captures, models, streams, watches.
  Map<String, dynamic>? get activity {
    final a = hardwareInfo?['activity'];
    return a is Map ? Map<String, dynamic>.from(a) : null;
  }

  /// Local mDNS name (``thoth-<name>.local``) — reported by the node
  /// heartbeat; derived from the device name when absent.
  String get hostname {
    final h = hardwareInfo?['hostname'] ??
        (hardwareInfo?['local_api'] is Map
            ? (hardwareInfo!['local_api'] as Map)['hostname']
            : null);
    if (h is String && h.isNotEmpty) return h;
    final label = name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9-]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return '${label.startsWith('thoth-') ? label : 'thoth-$label'}.local';
  }

  /// ``http://<hostname>:<port>`` for the local dashboard (port 5000).
  String get localUrl {
    final api = hardwareInfo?['local_api'];
    final port = api is Map && api['port'] != null ? api['port'] : 5000;
    return 'http://$hostname:$port';
  }

  factory ThothDevice.fromJson(Map<String, dynamic> json) {
    Map<String, dynamic>? hw;
    final raw = json['hardware_info'];
    if (raw is Map) {
      hw = Map<String, dynamic>.from(raw);
    } else if (raw is String && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) hw = Map<String, dynamic>.from(decoded);
      } catch (_) {/* non-JSON hardware_info — ignore */}
    }
    return ThothDevice(
      uuid: (json['device_uuid'] ?? json['device_id'] ?? '').toString(),
      name: (json['device_name'] ?? json['name'] ?? 'Device').toString(),
      online: json['online'] == true || json['is_online'] == true,
      deviceType: json['device_type']?.toString(),
      batteryLevel: json['battery_level'] is int
          ? json['battery_level'] as int
          : int.tryParse('${json['battery_level']}'),
      lastSeen: json['last_seen']?.toString(),
      hardwareInfo: hw,
    );
  }
}

final devicesProvider =
    FutureProvider.autoDispose<List<ThothDevice>>((ref) async {
  // Heartbeat cadence is ~30 s — re-fetch while any screen watches so
  // online state + hardware_info.activity stay live; autoDispose stops
  // the loop when nothing is looking.
  final timer = Timer.periodic(
    const Duration(seconds: 30),
    (_) => ref.invalidateSelf(),
  );
  ref.onDispose(timer.cancel);
  final client = BrainClient.instance;
  Map<String, dynamic> payload;
  try {
    payload = await client.getJson(
      '/device/list?include_offline=true',
      timeout: const Duration(seconds: 12),
    );
  } catch (_) {
    // Brain cold-starts can 500/timeout on the first hit — retry once
    // before surfacing an error so the page doesn't flash a failure.
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    payload = await client.getJson(
      '/device/list?include_offline=true',
      timeout: const Duration(seconds: 12),
    );
  }
  final items = (payload['devices'] ?? payload['data'] ?? []) as List;
  return items
      .map((e) => ThothDevice.fromJson(Map<String, dynamic>.from(e as Map)))
      .toList();
});
