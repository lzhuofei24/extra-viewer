import 'package:flutter_test/flutter_test.dart';
import 'package:best_viewer/src/modules/browser/original_image_budget.dart';

void main() {
  test('admission drops farthest originals before nearby images', () {
    expect(
        originalImageEvictions(
            currentId: 'current',
            budgetBytes: 100,
            decodedBytes: {'current': 40, 'near': 40, 'far': 40},
            distances: {'near': 1, 'far': 3}),
        ['far']);
  });
  test('oversized displayed original suppresses all speculative images', () {
    expect(
        originalImageEvictions(
            currentId: 'current',
            budgetBytes: 100,
            decodedBytes: {'current': 120, 'near': 10, 'far': 10},
            distances: {'near': 1, 'far': 3}),
        ['far', 'near']);
  });
}
