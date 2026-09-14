/// Evicts farthest speculative images first. The displayed image is never
/// evicted by this policy, even when it alone exceeds the speculative budget.
List<String> originalImageEvictions(
    {required String currentId,
    required int budgetBytes,
    required Map<String, int> decodedBytes,
    required Map<String, int> distances}) {
  var used = decodedBytes.values.fold<int>(0, (sum, bytes) => sum + bytes);
  final candidates = decodedBytes.keys.where((id) => id != currentId).toList()
    ..sort((a, b) => (distances[b] ?? 0).compareTo(distances[a] ?? 0));
  final removed = <String>[];
  for (final id in candidates) {
    if (used <= budgetBytes) break;
    removed.add(id);
    used -= decodedBytes[id]!;
  }
  return removed;
}
