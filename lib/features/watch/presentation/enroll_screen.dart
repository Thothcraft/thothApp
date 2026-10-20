import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../context/application/context_providers.dart';
import '../../context/domain/models.dart';
import '../../earbuds/application/earbuds_providers.dart';
import '../application/watch_providers.dart';
import '../data/watch_link.dart';

/// Wearable enrollment (Part 3) — generic flow for PineTime:
/// discover → identify firmware → pair/bond → register logical device →
/// associate with a person entity → verify IMU.
///
/// The watch IS NOT permanently tethered to the phone: the phone relays
/// until the node can subscribe directly. The status copy states which
/// side currently observes the wearable.
class EnrollScreen extends ConsumerStatefulWidget {
  const EnrollScreen({super.key});

  @override
  ConsumerState<EnrollScreen> createState() => _EnrollScreenState();
}

enum _EnrollStep { discover, pair, associate, verify, done }

class _EnrollScreenState extends ConsumerState<EnrollScreen> {
  _EnrollStep _step = _EnrollStep.discover;
  List<ScanResult> _found = const [];
  StreamSubscription<List<ScanResult>>? _sub;
  String? _pickedBleId;
  String? _error;
  bool _imuVerified = false;
  bool _creatingPerson = false;
  final _personName = TextEditingController();
  Timer? _verifyTimer;
  int _motionRx = 0;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  Future<void> _scan() async {
    _sub?.cancel();
    setState(() {
      _found = const [];
      _step = _EnrollStep.discover;
    });
    _sub = WatchLink.scan().listen((results) {
      if (!mounted) return;
      setState(() => _found =
          results.where(WatchLink.looksLikeWatch).toList(),);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _verifyTimer?.cancel();
    super.dispose();
  }

  Future<void> _pairDevice(BluetoothDevice device, String name) async {
    setState(() {
      _pickedBleId = device.remoteId.str;
      _step = _EnrollStep.pair;
      _error = null;
    });
    try {
      final record = await ref
          .read(watchManagerProvider.notifier)
          .pairAndConnect(device.remoteId.str,
              name: name.isNotEmpty ? name : 'PineTime',);
      // Register the logical entity + relationship in context.
      final repo = ref.read(contextRepoProvider);
      await repo.upsertEntity(ContextEntity(
        id: 'wearable:${record.deviceUuid}',
        kind: 'wearable',
        name: record.name,
        attributes: {'transport': 'ble', 'ble_id': record.bleId},
      ),);
      setState(() => _step = _EnrollStep.associate);
      _startImuVerify(record.bleId);
    } catch (e) {
      setState(() {
        _step = _EnrollStep.discover;
        _error = 'pairing failed: $e';
      });
    }
  }

  Future<void> _associate(String personEntity) async {
    final repo = ref.read(contextRepoProvider);
    final bleId = _pickedBleId;
    if (bleId == null) return;
    try {
      final uuid = await ref.read(watchListProvider.future).then((l) =>
          l.where((w) => w.bleId == bleId).firstOrNull?.deviceUuid ?? bleId,);
      // person —wears→ wearable ; wearable —worn_by→ person
      await repo.createRelationship(
          subject: personEntity,
          predicate: 'wears',
          object: 'wearable:$uuid',
          source: 'thoth-app/enroll',);
      await repo.createRelationship(
          subject: 'wearable:$uuid',
          predicate: 'worn_by',
          object: personEntity,
          source: 'thoth-app/enroll',);
      setState(() => _step = _EnrollStep.verify);
    } catch (e) {
      setState(() => _error = 'association failed: $e');
    }
  }

  /// Watches the phone's own Bluetooth already owns — paired in Android
  /// settings or connected at the system level. Enrolling one attaches
  /// the app's GATT link in parallel; the OS keeps owning the bond.
  Widget _systemWatches() {
    return Consumer(builder: (context, ref, _) {
      final sys = ref.watch(systemAccessoriesProvider).valueOrNull ??
          const <SystemAccessory>[];
      final watches = sys
          .where((d) => d.kind == AccessoryKind.watch)
          .toList();
      if (watches.isEmpty) return const SizedBox.shrink();
      return Column(children: [
        const Padding(
          padding: EdgeInsets.only(bottom: 4),
          child: Text('Paired on this phone',
              style: TextStyle(fontSize: 11, color: Colors.black45),),
        ),
        for (final d in watches)
          ListTile(
            dense: true,
            leading: const Icon(Icons.watch),
            title: Text(d.displayName),
            subtitle: Text(
                d.systemConnected ? 'connected' : 'paired',
                style: const TextStyle(fontSize: 11),),
            trailing: FilledButton.tonal(
                onPressed: () => _pairDevice(d.device, d.displayName),
                child: const Text('Enroll'),),
          ),
        const Divider(height: 8),
      ],);
    },);
  }

  void _startImuVerify(String bleId) {
    _verifyTimer?.cancel();
    _verifyTimer =
        Timer.periodic(const Duration(seconds: 1), (_) async {
      final relay = ref.read(watchManagerProvider)[bleId];
      final rx = relay?.link?.motionRx ?? 0;
      if (rx > _motionRx) {
        _motionRx = rx;
        _verifyTimer?.cancel();
        if (mounted) setState(() => _imuVerified = true);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Enroll a wearable')),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        const Text(
            'The phone relays the wearable until the node can observe it '
            'directly — enrollment only binds identity, not a permanent '
            'relay.',
            style: TextStyle(color: Colors.black54, fontSize: 12),),
        const SizedBox(height: 16),

        // ── discover ────────────────────────────────────────────────────
        _stepCard(
          0, 'Discover', _step.index >= 1,
          _step == _EnrollStep.discover
              ? Column(children: [
                  _systemWatches(),
                  for (final r in _found)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.watch_outlined),
                      title: Text(r.advertisementData.advName.isNotEmpty
                          ? r.advertisementData.advName
                          : r.device.remoteId.str,),
                      subtitle: Text('${r.rssi} dBm',
                          style: const TextStyle(fontSize: 11),),
                      trailing: FilledButton.tonal(
                          onPressed: () => _pairDevice(
                              r.device, r.advertisementData.advName),
                          child: const Text('Enroll'),),
                    ),
                  if (_found.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text(
                          'Scanning for InfiniTime wearables…\n'
                          'Or pair the watch in Android Bluetooth '
                          'settings — it shows above.',
                          textAlign: TextAlign.center,),
                    ),
                ],)
              : const SizedBox.shrink(),
        ),

        // ── associate ───────────────────────────────────────────────────
        _stepCard(
          1, 'Associate with a person', _step.index >= 3,
          _step == _EnrollStep.associate
              ? _personPicker()
              : const SizedBox.shrink(),
        ),

        // ── verify ──────────────────────────────────────────────────────
        _stepCard(
          2, 'Verify IMU', _step == _EnrollStep.done,
          _step.index >= 3
              ? ListTile(
                  dense: true,
                  leading: Icon(
                      _imuVerified
                          ? Icons.check_circle
                          : Icons.hourglass_top,
                      color:
                          _imuVerified ? Colors.green : Colors.orange,
                      size: 20,),
                  title: Text(_imuVerified
                      ? 'Motion samples arriving'
                      : 'Waiting for IMU samples…',),
                  subtitle: const Text(
                      'The node picks the stream up from Brain evidence — '
                      'the phone relay can drop after this.',
                      style: TextStyle(fontSize: 11),),
                )
              : const SizedBox.shrink(),
        ),

        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(_error!,
                style: TextStyle(
                    color: Theme.of(context).colorScheme.error,),),
          ),
        const SizedBox(height: 24),
        if (_step.index >= 3)
          FilledButton.icon(
            icon: const Icon(Icons.done),
            label: const Text('Done'),
            onPressed: () => context.go('/watch'),
          ),
      ],),
    );
  }

  Widget _personPicker() {
    return Consumer(builder: (context, ref, _) {
      final snap = ref.watch(contextSnapshotProvider);
      final people = snap.valueOrNull?.entities
              .where((e) => e.kind == 'person')
              .toList() ??
          const <ContextEntity>[];
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (final p in people)
          ListTile(
            dense: true,
            leading: const Icon(Icons.person_outline),
            title: Text(p.name ?? p.id),
            onTap: () => unawaited(_associate(p.id)),
          ),
        Row(children: [
          Expanded(
            child: TextField(
              controller: _personName,
              decoration: const InputDecoration(
                  hintText: 'New person name', isDense: true,),
            ),
          ),
          TextButton(
            onPressed: _creatingPerson
                ? null
                : () async {
                    final name = _personName.text.trim();
                    if (name.isEmpty) return;
                    setState(() => _creatingPerson = true);
                    try {
                      final id = 'person:${name.toLowerCase().replaceAll(
                          RegExp(r'[^a-z0-9]+'), '-',)}';
                      await ref.read(contextRepoProvider).upsertEntity(
                          ContextEntity(
                              id: id, kind: 'person', name: name,),);
                      await _associate(id);
                    } finally {
                      if (mounted) {
                        setState(() => _creatingPerson = false);
                      }
                    }
                  },
            child: const Text('Create'),
          ),
        ],),
      ],);
    },);
  }

  Widget _stepCard(int idx, String title, bool done, Widget child) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ExpansionTile(
        initiallyExpanded: !done,
        leading: Icon(
            done ? Icons.check_circle : Icons.circle_outlined,
            color: done ? Colors.green : Colors.grey,
            size: 20,),
        title: Text(title, style: const TextStyle(fontSize: 14)),
        children: [
          Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: child,),
        ],
      ),
    );
  }
}
