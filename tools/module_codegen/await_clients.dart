import 'dart:io';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:path/path.dart' as p;

void main(List<String> paths) {
  final root = p.normalize(p.join(Directory.current.path, '../..'));
  for (final path in paths) {
    final file = File(p.join(root, path));
    final content = file.readAsStringSync();
    final unit = parseString(content: content, throwIfDiagnostics: false).unit;
    final visitor = _AwaitClients();
    unit.accept(visitor);
    var result = content;
    for (final edit
        in (visitor.edits.values.toList()
          ..sort((a, b) => b.start.compareTo(a.start)))) {
      result = result.replaceRange(edit.start, edit.end, edit.value);
    }
    file.writeAsStringSync(result);
    stdout.writeln('$path: ${visitor.edits.length} transport edits');
  }
}

class _Edit {
  _Edit(this.start, this.end, this.value);
  final int start, end;
  final String value;
}

class _AwaitClients extends RecursiveAstVisitor<void> {
  final edits = <String, _Edit>{};
  void add(int start, int end, String value) =>
      edits['$start:$end'] = _Edit(start, end, value);
  @override
  void visitMethodInvocation(MethodInvocation node) {
    super.visitMethodInvocation(node);
    if (!{
      'library',
      'builds',
      'repository',
      'widget.repository',
      '_repository',
    }.contains(node.target?.toSource())) {
      return;
    }
    if (node.parent is AwaitExpression) return;
    FunctionBody? body;
    for (
      AstNode? parent = node.parent;
      parent != null;
      parent = parent.parent
    ) {
      if (parent is FunctionBody) {
        body = parent;
        break;
      }
    }
    if (body == null || body.parent is ConstructorDeclaration) return;
    if (body.parent case MethodDeclaration m
        when m.name.lexeme == 'build' || m.isGetter) {
      return;
    }
    add(node.offset, node.offset, '(await ');
    add(node.end, node.end, ')');
    if (!body.isAsynchronous) {
      add(body.offset, body.offset, 'async ');
      final declaration = body.parent;
      if (declaration is MethodDeclaration && declaration.returnType != null) {
        final type = declaration.returnType!;
        if (!type.toSource().startsWith('Future')) {
          add(type.offset, type.end, 'Future<${type.toSource()}>');
        }
      }
    }
  }
}
