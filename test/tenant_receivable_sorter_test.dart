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

  test('groups by property, unit, and contract before sorting due dates', () {
    final installments = [
      {
        'id': 1,
        'property_name': 'Beta',
        'unit_number': '1',
        'contract_id': 10,
        'due_date': '2026-01-01',
      },
      {
        'id': 2,
        'property_name': 'Alpha',
        'unit_number': '10',
        'contract_id': 12,
        'due_date': '2026-01-01',
      },
      {
        'id': 3,
        'property_name': 'Alpha',
        'unit_number': '2',
        'contract_id': 11,
        'due_date': '2026-12-01',
      },
      {
        'id': 4,
        'property_name': 'Alpha',
        'unit_number': '2',
        'contract_id': 11,
        'due_date': '2026-11-01',
      },
    ];

    expect(
      sortInstallmentsByDueDate(installments).map((row) => row['id']),
      [4, 3, 2, 1],
    );
  });

  test('filters receivables by property and contract without mutating input', () {
    final receivables = List<Map<String, dynamic>>.unmodifiable([
      {'id': 1, 'property_id': 3, 'contract_id': 8},
      {'id': 2, 'property_id': 3, 'contract_id': 9},
      {'id': 3, 'property_id': 4, 'contract_id': 10},
    ]);

    final filtered = filterTenantReceivables(
      receivables: receivables,
      propertyId: 3,
      contractId: 9,
    );

    expect(filtered.map((row) => row['id']), [2]);
    expect(receivables.length, 3);
  });
}
