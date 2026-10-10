import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../data/chat_repository.dart';

/// Chat — the context-grounded assistant surface backed by
/// Brain ``POST /v1/chat`` (rich answers + widgets + context_used).
class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _repo = ChatRepository();
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final List<_Msg> _msgs = [];
  final List<ChatAttachment> _pending = [];
  bool _sending = false;
  // Model pick sent to /v1/chat — the hub maps '4'→gpt-4o-class,
  // '5'→gpt-5, '6'→gpt-6 (env-overridable server-side).
  String _model = '4';

  static const _modelChoices = {
    '4': '4 · gpt-4o',
    '5': '5 · gpt-5',
    '6': '6 · gpt-6',
  };

  static const _suggestions = [
    'What can you see right now?',
    'Who is home?',
    'Where is the watch?',
    'What happened in the last hour?',
  ];

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send([String? preset]) async {
    final text = (preset ?? _input.text).trim();
    if ((text.isEmpty && _pending.isEmpty) || _sending) return;
    final atts = List<ChatAttachment>.from(_pending);
    setState(() {
      _sending = true;
      _pending.clear();
      _input.clear();
      _msgs.add(_Msg.user(text, atts));
      _msgs.add(_Msg.thinking());
    });
    _scrollToEnd();
    try {
      final history = _msgs
          .where((m) => !m.thinking && m.content.isNotEmpty)
          .map((m) => ChatTurn(
              role: m.isUser ? 'user' : 'assistant', content: m.content,),)
          .toList();
      final ans = await _repo.send(text,
          history: history.length > 12
              ? history.sublist(history.length - 12)
              : history,
          attachments: atts,
          model: _model,);
      if (!mounted) return;
      setState(() {
        _msgs.removeWhere((m) => m.thinking);
        _msgs.add(_Msg.assistant(ans));
      });
    } on DioException catch (e) {
      if (!mounted) return;
      final code = e.response?.statusCode;
      final detail = e.response?.data is Map
          ? '${e.response?.data['detail'] ?? ''}'
          : '';
      setState(() {
        _msgs.removeWhere((m) => m.thinking);
        _msgs.add(_Msg.error(switch (code) {
          402 || 429 =>
            'Inference quota reached — upgrade your plan or wait for the monthly reset.',
          503 =>
            'Assistant is not configured on the server yet (missing model key).',
          _ => 'Chat failed${code != null ? ' ($code)' : ''}'
              '${detail.isNotEmpty ? ': $detail' : ''}',
        },),);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _msgs.removeWhere((m) => m.thinking);
        _msgs.add(_Msg.error('Chat failed: $e'));
      });
    } finally {
      if (mounted) {
        setState(() => _sending = false);
        _scrollToEnd();
      }
    }
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut,);
      }
    });
  }

  Future<void> _attach() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: [
        'png', 'jpg', 'jpeg', 'gif', 'webp', 'heic',
        'txt', 'md', 'csv', 'json', 'log', 'pdf',
      ],
      withData: true,
    );
    if (picked == null || picked.files.isEmpty) return;
    final f = picked.files.first;
    final bytes = f.bytes;
    if (bytes == null) return;
    const maxBytes = 8 * 1024 * 1024;
    if (bytes.length > maxBytes) {
      _snack('${f.name} exceeds 8 MB');
      return;
    }
    final ext = f.extension?.toLowerCase() ?? '';
    final mime = switch (ext) {
      'png' => 'image/png',
      'jpg' || 'jpeg' => 'image/jpeg',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      'heic' => 'image/heic',
      'pdf' => 'application/pdf',
      'json' => 'application/json',
      'csv' => 'text/csv',
      _ => 'text/plain',
    };
    setState(() => _pending.add(ChatAttachment(
        name: f.name,
        mime: mime,
        dataB64: base64Encode(bytes),),),);
  }

  void _snack(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Row(children: [
          Icon(Icons.auto_awesome, size: 20),
          SizedBox(width: 8),
          Text('Assistant'),
        ],),
        actions: [
          IconButton(
            tooltip: 'What the assistant sees',
            icon: const Icon(Icons.visibility_outlined),
            onPressed: _showContext,
          ),
        ],
      ),
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: _msgs.isEmpty
                ? _emptyState()
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                    itemCount: _msgs.length,
                    itemBuilder: (c, i) => _bubble(_msgs[i]),
                  ),
          ),
          if (_pending.isNotEmpty)
            SizedBox(
              height: 40,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  for (final a in _pending)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: InputChip(
                        avatar: Icon(
                            a.mime.startsWith('image/')
                                ? Icons.image
                                : Icons.description,
                            size: 16,),
                        label: Text(a.name,
                            style: const TextStyle(fontSize: 12),),
                        onDeleted: () =>
                            setState(() => _pending.remove(a)),
                      ),
                    ),
                ],
              ),
            ),
          _modelPicker(),
          _composer(),
        ],),
      ),
    );
  }

  Widget _modelPicker() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 0),
      child: Row(children: [
        const Icon(Icons.psychology,
            size: 16, color: Colors.grey,),
        const SizedBox(width: 8),
        const Text('Model',
            style: TextStyle(fontSize: 11, color: Colors.grey),),
        const SizedBox(width: 8),
        Expanded(
          child: SegmentedButton<String>(
            segments: [
              for (final e in _modelChoices.entries)
                ButtonSegment(
                    value: e.key,
                    label: Text(e.value,
                        style: const TextStyle(fontSize: 11),),),
            ],
            selected: {_model},
            showSelectedIcon: false,
            style: SegmentedButton.styleFrom(
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              selectedBackgroundColor:
                  AppColors.primaryBlue.withValues(alpha: 0.16),
            ),
            onSelectionChanged: (s) =>
                setState(() => _model = s.first),
          ),
        ),
      ],),
    );
  }

  Widget _emptyState() {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const SizedBox(height: 48),
        const Icon(Icons.auto_awesome, size: 56, color: AppColors.primaryBlue),
        const SizedBox(height: 16),
        Text('Ask about your space',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge,),
        const SizedBox(height: 8),
        const Text(
          'Answers are grounded in your live semantic map, recent sensor '
          'descriptors and scenes — nothing is invented.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey, fontSize: 13),
        ),
        const SizedBox(height: 24),
        for (final s in _suggestions)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: OutlinedButton(
              onPressed: () => _send(s),
              child: Text(s),
            ),
          ),
      ],
    );
  }

  Widget _bubble(_Msg m) {
    if (m.thinking) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Row(children: [
          _Avatar(),
          SizedBox(width: 8),
          SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),),
          SizedBox(width: 8),
          Text('Thinking…', style: TextStyle(color: Colors.grey)),
        ],),
      );
    }
    final align =
        m.isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    final bubble = Container(
      constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.82,),
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: m.isUser
            ? AppColors.primaryBlue
            : m.isError
                ? Colors.red.withValues(alpha: 0.08)
                : Theme.of(context)
                    .colorScheme
                    .surfaceContainerHighest,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(16),
          topRight: const Radius.circular(16),
          bottomLeft: Radius.circular(m.isUser ? 16 : 4),
          bottomRight: Radius.circular(m.isUser ? 4 : 16),
        ),
      ),
      child: m.isUser
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final a in m.attachments)
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(
                        a.mime.startsWith('image/')
                            ? Icons.image
                            : Icons.attach_file,
                        size: 14,
                        color: Colors.white70,),
                    const SizedBox(width: 4),
                    Flexible(
                        child: Text(a.name,
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 11,),
                            overflow: TextOverflow.ellipsis,),),
                  ],),
                if (m.attachments.isNotEmpty && m.content.isNotEmpty)
                  const SizedBox(height: 4),
                if (m.content.isNotEmpty)
                  SelectableText(m.content,
                      style: const TextStyle(color: Colors.white),),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _MarkdownText(m.content,
                    color: m.isError
                        ? Colors.red.shade700
                        : Theme.of(context)
                            .colorScheme
                            .onSurface,),
                if (m.modelId != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(m.modelId!,
                        style: const TextStyle(
                            fontSize: 10, color: Colors.grey,),),
                  ),
                for (final w in m.widgets) _WidgetView(w, _send),
                if (m.contextUsed != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: InkWell(
                      onTap: () => _showContextDialog(m.contextUsed!),
                      child: const Row(mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.dataset_outlined,
                                size: 14, color: Colors.grey,),
                            SizedBox(width: 4),
                            Text('context used',
                                style: TextStyle(
                                    fontSize: 11, color: Colors.grey,),),
                          ],),
                    ),
                  ),
              ],
            ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        mainAxisAlignment: m.isUser
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!m.isUser) const _Avatar(),
          if (!m.isUser) const SizedBox(width: 8),
          Flexible(
            child: Column(crossAxisAlignment: align, children: [bubble]),
          ),
        ],
      ),
    );
  }

  Widget _composer() {
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(
            top: BorderSide(
                color: Theme.of(context).dividerColor.withValues(alpha: 0.4),),),
      ),
      child: Row(children: [
        IconButton(
          tooltip: 'Attach a file or image',
          icon: const Icon(Icons.attach_file),
          onPressed: _sending ? null : _attach,
        ),
        Expanded(
          child: TextField(
            controller: _input,
            minLines: 1,
            maxLines: 5,
            textCapitalization: TextCapitalization.sentences,
            onSubmitted: (_) => _send(),
            decoration: const InputDecoration(
              hintText: 'Ask the assistant…',
              border: InputBorder.none,
              isDense: true,
            ),
          ),
        ),
        IconButton(
          tooltip: 'Send',
          icon: const Icon(Icons.send, color: AppColors.primaryBlue),
          onPressed: _sending ? null : () => _send(),
        ),
      ],),
    );
  }

  Future<void> _showContext() async {
    try {
      final bundle = await _repo.contextBundle();
      if (!mounted) return;
      _showContextDialog(bundle);
    } catch (e) {
      _snack('Could not fetch context bundle: $e');
    }
  }

  void _showContextDialog(Map<String, dynamic> bundle) {
    final map = bundle['map'] is Map
        ? Map<String, dynamic>.from(bundle['map'] as Map)
        : const <String, dynamic>{};
    final entities = (map['entities'] as List?)?.length ?? 0;
    final rels = (map['relationships'] as List?)?.length ?? 0;
    final states = (map['states'] as List?)?.length ?? 0;
    final desc = (bundle['descriptors'] as List?)?.length ?? 0;
    final scenes = (bundle['scenes'] as List?)?.length ?? 0;
    final usage = bundle['usage'] is Map
        ? Map<String, dynamic>.from(bundle['usage'] as Map)
        : const <String, dynamic>{};
    showDialog(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('What the model sees'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _ctxRow('Entities', '$entities'),
              _ctxRow('Relationships', '$rels'),
              _ctxRow('Live states', '$states'),
              _ctxRow('Descriptor aggregates', '$desc'),
              _ctxRow('Scenes', '$scenes'),
              _ctxRow('Window', '${bundle['window_s'] ?? '?'}s'),
              if (usage.isNotEmpty) ...[
                const Divider(),
                _ctxRow('Inference used', '${usage['used'] ?? '?'}'
                    '${usage['limit'] != null ? ' / ${usage['limit']}' : ''}'),
              ],
              const Divider(),
              SelectableText(
                const JsonEncoder.withIndent('  ').convert(bundle),
                style: const TextStyle(
                    fontFamily: 'monospace', fontSize: 10.5,),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c), child: const Text('Close'),),
        ],
      ),
    );
  }

  Widget _ctxRow(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [Text(k), Text(v,
              style: const TextStyle(fontWeight: FontWeight.w600),),],
        ),
      );
}

class _Msg {
  _Msg.user(String text, List<ChatAttachment> atts)
      : isUser = true,
        isError = false,
        thinking = false,
        content = text,
        attachments = atts,
        widgets = const [],
        contextUsed = null,
        modelId = null;

  _Msg.assistant(ChatAnswer a)
      : isUser = false,
        isError = false,
        thinking = false,
        content = a.answer,
        attachments = const [],
        widgets = a.widgets,
        contextUsed = a.contextUsed,
        modelId = a.modelId;

  _Msg.error(String msg)
      : isUser = false,
        isError = true,
        thinking = false,
        content = msg,
        attachments = const [],
        widgets = const [],
        contextUsed = null,
        modelId = null;

  _Msg.thinking()
      : isUser = false,
        isError = false,
        thinking = true,
        content = '',
        attachments = const [],
        widgets = const [],
        contextUsed = null,
        modelId = null;

  final bool isUser;
  final bool isError;
  final bool thinking;
  final String content;
  final List<ChatAttachment> attachments;
  final List<Map<String, dynamic>> widgets;
  final Map<String, dynamic>? contextUsed;
  final String? modelId;
}

class _Avatar extends StatelessWidget {
  const _Avatar();
  @override
  Widget build(BuildContext context) => const CircleAvatar(
        radius: 14,
        backgroundColor: AppColors.primaryBlue,
        child: Icon(Icons.auto_awesome, size: 14, color: Colors.white),
      );
}

// ---------------------------------------------------------------------------
// Rich widgets — the shapes chat.py promises: list, key_values, table,
// states, questions.
// ---------------------------------------------------------------------------

class _WidgetView extends StatelessWidget {
  const _WidgetView(this.w, this.onQuestion);
  final Map<String, dynamic> w;
  final void Function(String) onQuestion;

  @override
  Widget build(BuildContext context) {
    final title = w['title'] as String?;
    Widget body;
    switch (w['type']) {
      case 'list':
        body = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final it in (w['items'] as List? ?? const []))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 1),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('• '),
                    Expanded(child: Text('$it',
                        style: const TextStyle(fontSize: 13),),),
                  ],
                ),
              ),
          ],
        );
      case 'key_values':
        body = Column(
          children: [
            for (final it in (w['items'] as List? ?? const []))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 1),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('${(it as Map)['label'] ?? ''}',
                        style: const TextStyle(
                            fontSize: 13, color: Colors.grey,),),
                    Flexible(
                        child: Text('${it['value'] ?? ''}',
                            style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,),),),
                  ],
                ),
              ),
          ],
        );
      case 'table':
        final cols = (w['columns'] as List? ?? const [])
            .map((c) => '$c')
            .toList();
        final rows = (w['rows'] as List? ?? const [])
            .map((r) => (r as List).map((c) => '$c').toList())
            .toList();
        body = SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Table(
            defaultColumnWidth: const IntrinsicColumnWidth(),
            children: [
              TableRow(children: [
                for (final cName in cols)
                  Padding(
                    padding: const EdgeInsets.only(right: 16, bottom: 4),
                    child: Text(cName,
                        style: const TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w700,),),
                  ),
              ],),
              for (final r in rows)
                TableRow(children: [
                  for (final cell in r)
                    Padding(
                      padding:
                          const EdgeInsets.only(right: 16, top: 2),
                      child: Text(cell,
                          style: const TextStyle(fontSize: 12),),
                    ),
                ],),
            ],
          ),
        );
      case 'states':
        body = Column(
          children: [
            for (final it in (w['items'] as List? ?? const []))
              if (it is Map)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                      it['confirmed'] == true
                          ? Icons.verified
                          : Icons.help_outline,
                      size: 16,
                      color: it['confirmed'] == true
                          ? Colors.green
                          : Colors.orange,),
                  title: Text('${it['key'] ?? ''}',
                      style: const TextStyle(fontSize: 12.5),),
                  subtitle: Text('${it['entity'] ?? ''} → ${it['value']}',
                      style: const TextStyle(fontSize: 11),),
                  trailing: it['confidence'] != null
                      ? Text(
                          '${((it['confidence'] as num) * 100).round()}%',
                          style: const TextStyle(
                              fontSize: 11, color: Colors.grey,),)
                      : null,
                ),
          ],
        );
      case 'questions':
        body = Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            for (final q in (w['items'] as List? ?? const []))
              ActionChip(
                label: Text('$q', style: const TextStyle(fontSize: 12)),
                onPressed: () => onQuestion('$q'),
              ),
          ],
        );
      default:
        body = Text('${w['type']}: ${w['items'] ?? ''}',
            style: const TextStyle(fontSize: 12, color: Colors.grey),);
    }
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
            color:
                Theme.of(context).dividerColor.withValues(alpha: 0.5),),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null && title.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(title,
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w700,),),
            ),
          body,
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Markdown-lite — bold/italic/code/headings/bullets → styled TextSpans.
// ---------------------------------------------------------------------------

class _MarkdownText extends StatelessWidget {
  const _MarkdownText(this.text, {required this.color});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final base = TextStyle(color: color, fontSize: 14, height: 1.35);
    final spans = <InlineSpan>[];
    for (final line in text.split('\n')) {
      var l = line;
      var style = base;
      var prefix = '';
      if (l.startsWith('### ')) {
        l = l.substring(4);
        style = base.copyWith(fontWeight: FontWeight.w800, fontSize: 15);
      } else if (l.startsWith('## ')) {
        l = l.substring(3);
        style = base.copyWith(fontWeight: FontWeight.w800, fontSize: 16);
      } else if (l.startsWith('# ')) {
        l = l.substring(2);
        style = base.copyWith(fontWeight: FontWeight.w800, fontSize: 17);
      } else if (RegExp(r'^\s*[-*•] ').hasMatch(l)) {
        l = l.replaceFirst(RegExp(r'^\s*[-*•] '), '');
        prefix = '  •  ';
      } else if (RegExp(r'^\s*\d+\. ').hasMatch(l)) {
        final m = RegExp(r'^\s*(\d+)\. ').firstMatch(l)!;
        prefix = '  ${m.group(1)}.  ';
        l = l.substring(m.end);
      }
      if (prefix.isNotEmpty) {
        spans.add(TextSpan(text: prefix, style: style));
      }
      spans.addAll(_inline(l, style));
      spans.add(const TextSpan(text: '\n'));
    }
    if (spans.isNotEmpty) spans.removeLast(); // trailing newline
    return SelectableText.rich(TextSpan(children: spans));
  }

  static List<InlineSpan> _inline(String s, TextStyle base) {
    final spans = <InlineSpan>[];
    final re = RegExp(
        r'(\*\*(.+?)\*\*)|(\*(.+?)\*)|(`(.+?)`)|(__(.+?)__)',);
    var pos = 0;
    for (final m in re.allMatches(s)) {
      if (m.start > pos) {
        spans.add(TextSpan(text: s.substring(pos, m.start), style: base));
      }
      if (m.group(2) != null || m.group(7) != null) {
        spans.add(TextSpan(
            text: m.group(2) ?? m.group(7),
            style: base.copyWith(fontWeight: FontWeight.w700),),);
      } else if (m.group(4) != null) {
        spans.add(TextSpan(
            text: m.group(4),
            style: base.copyWith(fontStyle: FontStyle.italic),),);
      } else if (m.group(6) != null) {
        spans.add(TextSpan(
            text: m.group(6),
            style: base.copyWith(
                fontFamily: 'monospace',
                fontSize: base.fontSize! - 1,
                backgroundColor: Colors.grey.withValues(alpha: 0.18),),),);
      }
      pos = m.end;
    }
    if (pos < s.length) {
      spans.add(TextSpan(text: s.substring(pos), style: base));
    }
    return spans;
  }
}
