import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/brain_client.dart';

/// Actuators/Automations tab — Brain-side rules (/v1/automation/rules) that
/// turn predictions/context into actuator commands, plus the ActionRequest
/// queue (/v1/automation/actions) showing what fired, queued, or failed.
class ActuatorsScreen extends ConsumerStatefulWidget {
  const ActuatorsScreen({super.key});

  @override
  ConsumerState<ActuatorsScreen> createState() => _ActuatorsScreenState();
}

class _ActuatorsScreenState extends ConsumerState<ActuatorsScreen> {
  List<Map<String, dynamic>> _rules = [];
  List<Map<String, dynamic>> _actions = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final client = BrainClient.instance;
      final rules = await client.getV1('/automation/rules');
      final actions = await client.getV1('/automation/actions');
      setState(() {
        _rules = (rules['rules'] as List? ?? const [])
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
        _actions = (actions['actions'] as List? ?? const [])
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _toggleRule(Map<String, dynamic> rule, bool enabled) async {
    try {
      await BrainClient.instance.postV1('/automation/rules', body: {
        'name': rule['name'],
        'when': _decode(rule['when']),
        'then': _decode(rule['then']),
        'cooldown_s': rule['cooldown_s'] ?? 0,
        'enabled': enabled,
      },);
      await _reload();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Toggle failed: $e')));
      }
    }
  }

  Map<String, dynamic> _decode(dynamic v) {
    if (v is Map) return Map<String, dynamic>.from(v);
    if (v is String && v.isNotEmpty) {
      try {
        return Map<String, dynamic>.from(json.decode(v));
      } catch (_) {}
    }
    return const {};
  }

  /// One-tap starters for the common rule shapes — every field stays
  /// editable in the sheet, nothing is hardcoded into the rule once
  /// saved. `actuator_id` defaults to `led`; change it to the real
  /// actuator on the target node (or `notify` for a phone push).
  static const _presets = <Map<String, dynamic>>[
    {
      'title': 'Watch linked → lights red',
      'name': 'watch-linked-red',
      'when': {'key': 'watch.link.v1',
               'contains': {'connected': true}},
      'then': {'actuator_id': 'led', 'operation': 'set_color',
               'params': {'rgb': [255, 0, 0]}},
    },
    {
      'title': 'Watch <10 m → lights green',
      'name': 'watch-near-green',
      'when': {'key': 'proximity.v1',
               'field': 'distance_m', 'max': 10},
      'then': {'actuator_id': 'led', 'operation': 'set_color',
               'params': {'rgb': [0, 255, 0]}},
    },
    {
      'title': 'Person at laptop → lights yellow',
      'name': 'person-at-laptop-yellow',
      'when': {'key': 'prediction', 'not_equals': 'no_face'},
      'then': {'actuator_id': 'led', 'operation': 'set_color',
               'params': {'rgb': [255, 255, 0]}},
    },
    {
      'title': 'Room occupied → phone notification',
      'name': 'room-occupied-notify',
      'when': {'key': 'occupancy.v1', 'contains': {'occupied': true}},
      'then': {'actuator_id': 'notify', 'operation': 'notify',
               'params': {'title': 'Thoth · room occupied',
                          'body': 'Presence detected in the room'},},
    },
  ];

  Future<void> _newRuleSheet() async {
    final nameCtl = TextEditingController();
    final whenCtl = TextEditingController(
        text: const JsonEncoder.withIndent('  ').convert(
            {'key': 'occupancy.v1',
             'contains': {'occupied': true}}),);
    final thenCtl = TextEditingController(
        text: const JsonEncoder.withIndent('  ').convert(
            {'actuator_id': 'notify', 'operation': 'notify',
             'params': {'title': 'Thoth', 'body': ''}},),);
    final coolCtl = TextEditingController(text: '0');
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => Padding(
          padding: EdgeInsets.only(
            left: 16, right: 16, top: 16,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('New automation rule',
                    style: Theme.of(ctx).textTheme.titleMedium,),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8, runSpacing: 8,
                  children: [
                    for (final p in _presets)
                      ActionChip(
                        label: Text(p['title'] as String),
                        onPressed: () => setS(() {
                          nameCtl.text = p['name'] as String;
                          whenCtl.text = const JsonEncoder.withIndent(
                              '  ').convert(p['when']);
                          thenCtl.text = const JsonEncoder.withIndent(
                              '  ').convert(p['then']);
                        },),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(controller: nameCtl,
                    decoration: const InputDecoration(
                        labelText: 'Rule name',
                        border: OutlineInputBorder(),),),
                const SizedBox(height: 8),
                TextField(controller: whenCtl, maxLines: 4,
                    style: const TextStyle(
                        fontFamily: 'monospace', fontSize: 12,),
                    decoration: const InputDecoration(
                        labelText: 'when (JSON)',
                        helperText:
                            'key · entity_id · equals · not_equals · '
                            'contains · field+min/max · min_confidence · '
                            'expr (whispy rule language over state values)',
                        border: OutlineInputBorder(),),),
                const SizedBox(height: 8),
                TextField(controller: thenCtl, maxLines: 6,
                    style: const TextStyle(
                        fontFamily: 'monospace', fontSize: 12,),
                    decoration: const InputDecoration(
                        labelText: 'then (JSON)',
                        helperText: 'actuator_id "notify" = push '
                            'notification to this phone',
                        border: OutlineInputBorder(),),),
                const SizedBox(height: 8),
                TextField(controller: coolCtl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                        labelText: 'cooldown seconds',
                        border: OutlineInputBorder(),),),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Save rule'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (saved != true) return;
    try {
      final when = json.decode(whenCtl.text);
      final then = json.decode(thenCtl.text);
      await BrainClient.instance.postV1('/automation/rules', body: {
        'name': nameCtl.text.trim(),
        'when': when, 'then': then,
        'cooldown_s': double.tryParse(coolCtl.text) ?? 0,
        'enabled': true,
      },);
      await _reload();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Save failed: $e')));
      }
    }
  }

  Future<void> _deleteRule(Map<String, dynamic> rule) async {
    try {
      await BrainClient.instance
          .deleteV1('/automation/rules/${rule['name']}');
      await _reload();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Delete failed: $e')));
      }
    }
  }

  Future<void> _evaluate() async {
    try {
      final res = await BrainClient.instance.postV1('/automation/evaluate');
      await _reload();
      if (mounted) {
        final fired = (res['fired'] as List? ?? const []).length;
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Evaluated — $fired rule(s) fired')),);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Evaluate failed: $e')));
      }
    }
  }

  Future<void> _redispatch(String actionId) async {
    try {
      await BrainClient.instance
          .postV1('/automation/actions/$actionId/dispatch');
      await _reload();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Dispatch failed: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          const TabBar(tabs: [
            Tab(text: 'Rules'),
            Tab(text: 'Actions'),
          ],),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(
                        child: Text('Failed to load\n$_error',
                            textAlign: TextAlign.center,),)
                    : TabBarView(children: [
                        _rulesTab(),
                        _actionsTab(),
                      ],),
          ),
        ],
      ),
    );
  }

  Widget _rulesTab() {
    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Row(children: [
            FilledButton.tonalIcon(
              icon: const Icon(Icons.play_arrow),
              label: const Text('Evaluate now'),
              onPressed: _evaluate,
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              icon: const Icon(Icons.add),
              label: const Text('New rule'),
              onPressed: _newRuleSheet,
            ),
          ],),
          const SizedBox(height: 8),
          if (_rules.isEmpty)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Center(
                child: Text(
                    'No automation rules yet.\nRules fire actuators when context changes — tap New rule to create one here.',
                    textAlign: TextAlign.center,),
              ),
            ),
          for (final r in _rules)
            Card(
              child: SwitchListTile(
                dense: true,
                title: Text('${r['name']}',
                    style: const TextStyle(fontSize: 14),),
                subtitle: Text(
                  'when ${_short(r['when'])} → then ${_short(r['then'])}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style:
                      const TextStyle(fontFamily: 'monospace', fontSize: 11),
                ),
                secondary: IconButton(
                  icon: const Icon(Icons.delete_outline, size: 20),
                  tooltip: 'Delete rule',
                  onPressed: () => _deleteRule(r),
                ),
                value: r['enabled'] != false,
                onChanged: (v) => _toggleRule(r, v),
              ),
            ),
        ],
      ),
    );
  }

  Widget _actionsTab() {
    return RefreshIndicator(
      onRefresh: _reload,
      child: _actions.isEmpty
          ? ListView(children: const [
              SizedBox(height: 120),
              Center(
                  child: Text(
                      'No action requests yet.\nThey appear when rules fire or actuators are called.',),),
            ],)
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: _actions.length,
              itemBuilder: (context, i) {
                final a = _actions[i];
                final status = '${a['status'] ?? 'queued'}';
                final queued = status == 'queued' || status == 'failed';
                return Card(
                  child: ListTile(
                    dense: true,
                    leading: Icon(
                      status == 'delivered'
                          ? Icons.check_circle
                          : status == 'failed'
                              ? Icons.error
                              : Icons.schedule,
                      color: status == 'delivered'
                          ? Colors.green
                          : status == 'failed'
                              ? Colors.red
                              : Colors.orange,
                      size: 20,
                    ),
                    title: Text(
                        '${a['actuator_id'] ?? a['action_id'] ?? 'action'}',
                        style: const TextStyle(fontSize: 13),),
                    subtitle: Text(
                      '${a['command'] ?? _short(a['payload'])} • $status',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontFamily: 'monospace', fontSize: 11,),
                    ),
                    trailing: queued
                        ? IconButton(
                            icon: const Icon(Icons.refresh, size: 20),
                            tooltip: 'Redispatch',
                            onPressed: () =>
                                _redispatch('${a['action_id']}'),
                          )
                        : null,
                  ),
                );
              },
            ),
    );
  }

  String _short(dynamic v) {
    final s = v is String ? v : json.encode(_decode(v));
    return s.length > 80 ? '${s.substring(0, 80)}…' : s;
  }
}
