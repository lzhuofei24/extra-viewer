import 'package:flutter/material.dart';

import '../core/domain/models.dart';
import '../modules/library/library_queries.dart';

class RuleDraft {
  const RuleDraft({
    required this.name,
    required this.entityTypes,
    required this.extensions,
    required this.scopeNodeId,
    required this.minSize,
    required this.maxSize,
    required this.modifiedWithinDays,
    required this.openedWithinDays,
    required this.defaultSort,
  });

  final String name;
  final List<EntityType> entityTypes;
  final List<String> extensions;
  final String? scopeNodeId;
  final int? minSize;
  final int? maxSize;
  final int? modifiedWithinDays;
  final int? openedWithinDays;
  final RuleSortMode defaultSort;
}

class RuleEditorDialog extends StatefulWidget {
  const RuleEditorDialog({super.key, required this.queries, this.initial});

  final LibraryQueries queries;
  final RuleDefinition? initial;

  @override
  State<RuleEditorDialog> createState() => _RuleEditorDialogState();
}

class _RuleEditorDialogState extends State<RuleEditorDialog> {
  late final TextEditingController _name =
      TextEditingController(text: widget.initial?.node.name ?? '');
  late final TextEditingController _minSize =
      TextEditingController(text: _megabytes(widget.initial?.minSize));
  late final TextEditingController _maxSize =
      TextEditingController(text: _megabytes(widget.initial?.maxSize));
  late final TextEditingController _modifiedDays = TextEditingController(
      text: widget.initial?.modifiedWithinDays?.toString() ?? '');
  late final TextEditingController _openedDays = TextEditingController(
      text: widget.initial?.openedWithinDays?.toString() ?? '');
  late final Set<EntityType> _types = {...?widget.initial?.entityTypes};
  late final Set<String> _extensions = {...?widget.initial?.extensions};
  late String? _scopeNodeId = widget.initial?.scopeNodeId;
  late RuleSortMode _sort =
      widget.initial?.defaultSort ?? RuleSortMode.lastOpened;
  RuleFilterOptions? _options;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadOptions();
  }

  @override
  void dispose() {
    _name.dispose();
    _minSize.dispose();
    _maxSize.dispose();
    _modifiedDays.dispose();
    _openedDays.dispose();
    super.dispose();
  }

  Future<void> _loadOptions() async {
    try {
      final options = await widget.queries
          .listRuleFilterOptions(entityTypes: _types.toList());
      if (!mounted) return;
      setState(() {
        _options = options;
        _loading = false;
        final available =
            options.extensionsByType.values.expand((e) => e).toSet();
        _extensions.removeWhere((extension) => !available.contains(extension));
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = '$error';
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final options = _options;
    return AlertDialog(
      title: Text(widget.initial == null ? '新建规则' : '编辑规则'),
      content: SizedBox(
        width: 560,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Text(_error!)
                : SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        TextField(
                          controller: _name,
                          decoration: const InputDecoration(labelText: '名称'),
                        ),
                        const SizedBox(height: 16),
                        const Text('文件类型'),
                        Wrap(
                          spacing: 8,
                          children: [
                            for (final type in EntityType.values)
                              FilterChip(
                                label: Text(_typeLabel(type)),
                                selected: _types.contains(type),
                                onSelected: (selected) async {
                                  setState(() => selected
                                      ? _types.add(type)
                                      : _types.remove(type));
                                  await _loadOptions();
                                },
                              ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        const Text('扩展名'),
                        if (options!.extensionsByType.values
                            .expand((values) => values)
                            .isEmpty)
                          const Text('当前类型没有可选扩展名')
                        else
                          Wrap(
                            spacing: 8,
                            children: [
                              for (final extension
                                  in options.extensionsByType.values
                                      .expand((values) => values)
                                      .toSet()
                                      .toList()
                                    ..sort())
                                FilterChip(
                                  label: Text(extension),
                                  selected: _extensions.contains(extension),
                                  onSelected: (selected) => setState(() =>
                                      selected
                                          ? _extensions.add(extension)
                                          : _extensions.remove(extension)),
                                ),
                            ],
                          ),
                        const SizedBox(height: 12),
                        DropdownButtonFormField<String?>(
                          initialValue: _scopeNodeId,
                          decoration:
                              const InputDecoration(labelText: '所在目录或分类'),
                          items: [
                            const DropdownMenuItem<String?>(
                                value: null, child: Text('不限位置')),
                            for (final node in options.scopeNodes)
                              DropdownMenuItem<String?>(
                                  value: node.id, child: Text(node.name)),
                          ],
                          onChanged: (value) => _scopeNodeId = value,
                        ),
                        const SizedBox(height: 12),
                        Row(children: [
                          Expanded(
                              child: TextField(
                            controller: _minSize,
                            keyboardType: TextInputType.number,
                            decoration:
                                const InputDecoration(labelText: '最小大小 (MB)'),
                          )),
                          const SizedBox(width: 12),
                          Expanded(
                              child: TextField(
                            controller: _maxSize,
                            keyboardType: TextInputType.number,
                            decoration:
                                const InputDecoration(labelText: '最大大小 (MB)'),
                          )),
                        ]),
                        const SizedBox(height: 12),
                        Row(children: [
                          Expanded(
                              child: TextField(
                            controller: _modifiedDays,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                                labelText: '最近修改 (天)',
                                hintText: '1 / 7 / 30 / 90'),
                          )),
                          const SizedBox(width: 12),
                          Expanded(
                              child: TextField(
                            controller: _openedDays,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                                labelText: '最近打开 (天)',
                                hintText: '1 / 7 / 30 / 90'),
                          )),
                        ]),
                        const SizedBox(height: 12),
                        DropdownButtonFormField<RuleSortMode>(
                          initialValue: _sort,
                          decoration: const InputDecoration(labelText: '默认排序'),
                          items: [
                            for (final sort in RuleSortMode.values)
                              DropdownMenuItem(
                                  value: sort, child: Text(_sortLabel(sort))),
                          ],
                          onChanged: (value) => _sort = value ?? _sort,
                        ),
                      ],
                    ),
                  ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(
            onPressed: _loading ? null : _submit, child: const Text('保存')),
      ],
    );
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '请输入规则名称');
      return;
    }
    Navigator.pop(
      context,
      RuleDraft(
        name: name,
        entityTypes: _types.toList(growable: false),
        extensions: _extensions.toList(growable: false),
        scopeNodeId: _scopeNodeId,
        minSize: _bytes(_minSize.text),
        maxSize: _bytes(_maxSize.text),
        modifiedWithinDays: _positiveInt(_modifiedDays.text),
        openedWithinDays: _positiveInt(_openedDays.text),
        defaultSort: _sort,
      ),
    );
  }
}

String _megabytes(int? bytes) =>
    bytes == null ? '' : (bytes / (1024 * 1024)).toStringAsFixed(1);

int? _bytes(String value) {
  final parsed = double.tryParse(value.trim());
  return parsed == null ? null : (parsed * 1024 * 1024).round();
}

int? _positiveInt(String value) {
  final parsed = int.tryParse(value.trim());
  return parsed == null || parsed < 1 ? null : parsed;
}

String _typeLabel(EntityType type) => switch (type) {
      EntityType.image => '图片',
      EntityType.video => '视频',
      EntityType.audio => '音乐',
      EntityType.text => '文本',
      EntityType.document => '文档',
    };

String _sortLabel(RuleSortMode sort) => switch (sort) {
      RuleSortMode.lastOpened => '最近打开',
      RuleSortMode.openCount => '访问次数',
      RuleSortMode.modified => '修改时间',
      RuleSortMode.name => '名称',
      RuleSortMode.size => '大小',
    };
