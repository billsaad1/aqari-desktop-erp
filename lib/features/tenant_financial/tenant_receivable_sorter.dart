List<Map<String, dynamic>> sortInstallmentsByDueDate(
  Iterable<Map<String, dynamic>> installments,
) {
  final sortedInstallments = List<Map<String, dynamic>>.of(installments);
  sortedInstallments.sort(
    (a, b) =>
        a['due_date'].toString().compareTo(b['due_date'].toString()),
  );
  return sortedInstallments;
}
