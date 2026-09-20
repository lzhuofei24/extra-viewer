import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

/// Derived DTOs only. Progress writes do not invalidate query domains.
class QueryCache {
  QueryCache({this.maxBytes = 16 * 1024 * 1024, this.maxEntries = 20000});
  final int maxBytes;
  final int maxEntries;
  final _entries = <String, _CachedValue>{};
  int _bytes = 0;
  String? _revision;

  void synchronize(Database db) {
    final revision = jsonEncode(db
        .select('''SELECT domain,revision FROM
      query_revisions WHERE scope_id='' ORDER BY domain''')
        .map((row) => row.values.toList())
        .toList());
    final dirty =
        db.select('SELECT 1 FROM query_revision_dirty LIMIT 1').isNotEmpty;
    if (_revision != revision || dirty) {
      _entries.clear();
      _bytes = 0;
      _revision = revision;
    }
  }

  Object? get(String key, int now) {
    final entry = _entries.remove(key);
    if (entry == null) return null;
    if (entry.expiresAt != null && now >= entry.expiresAt!) {
      _bytes -= entry.bytes;
      return null;
    }
    _entries[key] = entry;
    return entry.value;
  }

  void put(String key, Object value, {int? expiresAt}) {
    final previous = _entries.remove(key);
    if (previous != null) _bytes -= previous.bytes;
    final size = utf8.encode(jsonEncode(value)).length + key.length * 2 + 64;
    if (size > maxBytes || maxEntries < 1) return;
    while (_entries.isNotEmpty &&
        (_bytes + size > maxBytes || _entries.length >= maxEntries)) {
      _bytes -= _entries.remove(_entries.keys.first)!.bytes;
    }
    _entries[key] = _CachedValue(value, size, expiresAt);
    _bytes += size;
  }
}

class _CachedValue {
  const _CachedValue(this.value, this.bytes, this.expiresAt);
  final Object value;
  final int bytes;
  final int? expiresAt;
}
