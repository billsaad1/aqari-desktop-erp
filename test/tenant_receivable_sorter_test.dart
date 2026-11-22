import 'package:app/features/tenant_financial/tenant_receivable_sorter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('sorts read-only installment results using a mutable copy', () {
    final readOnlyInstallments = List<Map<String, dynamic>>.unmodifiable([
      {'id': 2, 'due_date': '2026-12-22'},
      {'id': 1, 'due_date': '2026-11-22'},
    ]);

    final sorted = sortInstallmentsByDueDate(readOnlyInstallments);

    expect(sorted.map((installment) => installment['id']), [1, 2]);
    expect(readOnlyInstallments.first['id'], 2);
  });
}
