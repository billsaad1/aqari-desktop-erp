int? _recordId(Map<String, dynamic> record, String key) {
  final value = record[key];
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '');
}

int _compareNaturalText(Object? left, Object? right) {
  final a = (left ?? '').toString().trim();
  final b = (right ?? '').toString().trim();
  final aNumber = int.tryParse(a);
  final bNumber = int.tryParse(b);
  if (aNumber != null && bNumber != null) return aNumber.compareTo(bNumber);
  return a.toLowerCase().compareTo(b.toLowerCase());
}

/// Sorts by lease context first so multiple properties and units are not
/// interleaved, then by due date and installment number within each contract.
List<Map<String, dynamic>> sortInstallmentsByDueDate(
  Iterable<Map<String, dynamic>> installments,
) {
  final sortedInstallments = List<Map<String, dynamic>>.of(installments);
  sortedInstallments.sort((a, b) {
    var comparison = _compareNaturalText(a['property_name'], b['property_name']);
    if (comparison != 0) return comparison;

    comparison = _compareNaturalText(a['unit_number'], b['unit_number']);
    if (comparison != 0) return comparison;

    comparison = (_recordId(a, 'contract_id') ?? -1).compareTo(
      _recordId(b, 'contract_id') ?? -1,
    );
    if (comparison != 0) return comparison;

    comparison = (a['due_date'] ?? '').toString().compareTo(
      (b['due_date'] ?? '').toString(),
    );
    if (comparison != 0) return comparison;

    comparison = (_recordId(a, 'installment_number') ?? -1).compareTo(
      _recordId(b, 'installment_number') ?? -1,
    );
    if (comparison != 0) return comparison;

    return (_recordId(a, 'id') ?? -1).compareTo(_recordId(b, 'id') ?? -1);
  });
  return sortedInstallments;
}

/// Applies the selected property and contract to installment or invoice rows.
/// A fresh list is returned and the source iterable is never mutated.
List<Map<String, dynamic>> filterTenantReceivables({
  required Iterable<Map<String, dynamic>> receivables,
  int? propertyId,
  int? contractId,
}) {
  return receivables.where((row) {
    if (propertyId != null && _recordId(row, 'property_id') != propertyId) {
      return false;
    }
    if (contractId != null && _recordId(row, 'contract_id') != contractId) {
      return false;
    }
    return true;
  }).toList();
}
