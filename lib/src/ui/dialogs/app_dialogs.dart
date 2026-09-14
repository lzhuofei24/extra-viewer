import 'package:flutter/material.dart';

/// A simple text prompt dialog used for renaming, creating nodes, etc.
class TextPromptDialog extends StatefulWidget {
  const TextPromptDialog({
    super.key,
    required this.title,
    required this.label,
    required this.confirmLabel,
    this.hintText,
    this.initialValue,
  });

  final String title;
  final String label;
  final String confirmLabel;
  final String? hintText;
  final String? initialValue;

  @override
  State<TextPromptDialog> createState() => _TextPromptDialogState();

  static Future<String?> show(
    BuildContext context, {
    required String title,
    required String label,
    required String confirmLabel,
    String? hintText,
    String? initialValue,
  }) {
    return showDialog<String>(
      context: context,
      builder: (_) => TextPromptDialog(
        title: title,
        label: label,
        confirmLabel: confirmLabel,
        hintText: hintText,
        initialValue: initialValue,
      ),
    );
  }
}

class _TextPromptDialogState extends State<TextPromptDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialValue);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_controller.text);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(
          labelText: widget.label,
          hintText: widget.hintText,
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

/// Dialog for creating a directory index with an optional display name.
class DirectoryIndexDialog extends StatefulWidget {
  const DirectoryIndexDialog({
    super.key,
    required this.source,
    required this.initialName,
  });

  final String source;
  final String initialName;

  @override
  State<DirectoryIndexDialog> createState() => _DirectoryIndexDialogState();
}

class _DirectoryIndexDialogState extends State<DirectoryIndexDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialName);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_controller.text);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('新建目录索引'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.source,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _controller,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '索引名称（可选）',
                hintText: '默认使用目录最后一级名称',
              ),
              onSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('建立索引')),
      ],
    );
  }
}
