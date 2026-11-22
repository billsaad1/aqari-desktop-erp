enum TenantReceiptPaymentMethod {
  cash('cash'),
  bankTransfer('bank_transfer'),
  check('check');

  const TenantReceiptPaymentMethod(this.databaseValue);

  final String databaseValue;

  static TenantReceiptPaymentMethod? fromDatabase(Object? value) {
    final normalized = value?.toString().trim();
    for (final method in values) {
      if (method.databaseValue == normalized) return method;
    }
    return null;
  }

  static String? displayLabel({
    required Object? method,
    Object? reference,
    Object? bankName,
  }) {
    final parsed = fromDatabase(method);
    if (parsed == null) return null;
    final normalizedReference = reference?.toString().trim();
    final normalizedBankName = bankName?.toString().trim();
    final bankAlreadyIdentified = normalizedBankName != null &&
        (normalizedBankName.startsWith('بنك') ||
            normalizedBankName.startsWith('البنك') ||
            normalizedBankName.startsWith('مصرف'));
    final bankSuffix = normalizedBankName == null || normalizedBankName.isEmpty
        ? ''
        : ' — ${bankAlreadyIdentified ? normalizedBankName : 'بنك $normalizedBankName'}';
    final referenceSuffix = normalizedReference == null || normalizedReference.isEmpty
        ? ''
        : ' — مرجع $normalizedReference';

    return switch (parsed) {
      TenantReceiptPaymentMethod.cash => 'نقداً للصندوق',
      TenantReceiptPaymentMethod.bankTransfer =>
        'حوالة بنكية$bankSuffix$referenceSuffix',
      TenantReceiptPaymentMethod.check =>
        'شيك رقم ${normalizedReference == null || normalizedReference.isEmpty ? '—' : normalizedReference}$bankSuffix',
    };
  }
}
