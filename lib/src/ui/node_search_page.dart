import 'dart:async';
import 'package:flutter/material.dart';
import '../core/domain/models.dart';
import '../modules/library/library_queries.dart';

class NodeSearchPageView extends StatefulWidget {
  const NodeSearchPageView({super.key, required this.queries});
  final LibraryQueries queries;
  @override
  State<NodeSearchPageView> createState() => _NodeSearchPageViewState();
}

class _NodeSearchPageViewState extends State<NodeSearchPageView> {
  final _text = TextEditingController();
  Timer? _debounce;
  int _generation = 0;
  NodeSearchScope _scope = NodeSearchScope.all;
  List<NodeSearchResult> _items = [];
  bool _busy = false;
  bool _more = false;
  String? _error;

  void _changed() {
    _debounce?.cancel();
    _generation++;
    setState(() {
      _items = [];
      _more = false;
      _error = null;
      _busy = _text.text.trim().isNotEmpty;
    });
    _debounce = Timer(const Duration(milliseconds: 200), () => _search());
  }

  Future<void> _search({bool append = false}) async {
    final generation = ++_generation;
    final text = _text.text.trim();
    if (text.isEmpty) {
      setState(() => _busy = false);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final page = await widget.queries.searchNodes(NodeSearchQuery(
          text: text, scope: _scope, offset: append ? _items.length : 0));
      if (!mounted || generation != _generation) return;
      setState(() {
        _items = append ? [..._items, ...page.items] : page.items;
        _more = page.hasMore;
        _busy = false;
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _error = '搜索失败：$error';
        _busy = false;
      });
    }
  }

  @override
  void dispose() {
    _generation++;
    _debounce?.cancel();
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('搜索节点')),
        body: SafeArea(
            child: Column(children: [
          Padding(
              padding: const EdgeInsets.all(12),
              child: TextField(
                controller: _text,
                autofocus: true,
                onChanged: (_) => _changed(),
                onSubmitted: (_) {
                  _debounce?.cancel();
                  _search();
                },
                decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search), hintText: '输入节点名称'),
              )),
          Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Wrap(spacing: 8, children: [
                for (final scope in NodeSearchScope.values)
                  ChoiceChip(
                      label: Text(switch (scope) {
                        NodeSearchScope.all => '全部',
                        NodeSearchScope.directory => '目录',
                        NodeSearchScope.collection => '资料集',
                        NodeSearchScope.graph => '图'
                      }),
                      selected: _scope == scope,
                      onSelected: (_) {
                        _scope = scope;
                        _changed();
                      }),
              ])),
          SizedBox(
              height: 4, child: _busy ? const LinearProgressIndicator() : null),
          if (_error != null)
            Padding(padding: const EdgeInsets.all(12), child: Text(_error!)),
          Expanded(
              child: _items.isEmpty
                  ? Center(
                      child: Text(_busy
                          ? '正在搜索…'
                          : _text.text.trim().isEmpty
                              ? '按名称查找目录、资料集和图节点'
                              : '没有匹配的节点'))
                  : ListView.separated(
                      itemCount: _items.length + (_more ? 1 : 0),
                      separatorBuilder: (context, index) =>
                          const Divider(height: 1),
                      itemBuilder: (context, index) {
                        if (index == _items.length) {
                          return TextButton(
                              onPressed:
                                  _busy ? null : () => _search(append: true),
                              child: const Text('加载更多'));
                        }
                        final result = _items[index];
                        final type = switch (result.root.nodeType) {
                          NodeType.directoryIndexRoot => '目录',
                          NodeType.graphIndexRoot => '图',
                          _ => '资料集'
                        };
                        return ListTile(
                            dense: true,
                            title: Text(result.node.name),
                            subtitle: Text(
                                '$type · ${result.root.name}\n${result.breadcrumb.map((node) => node.name).join(' / ')}'),
                            isThreeLine: true,
                            onTap: () => Navigator.of(context).pop(result));
                      })),
        ])),
      );
}
