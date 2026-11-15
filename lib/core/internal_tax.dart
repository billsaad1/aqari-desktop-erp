/// Internal invoice tax arithmetic. This is a configurable calculation helper,
/// not a tax-regime or electronic-invoicing compliance implementation.
class InternalTax {
  const InternalTax._();

  static bool isValidRate(double rate) =>
      rate.isFinite && rate >= 0 && rate <= 100;

  static int toMinorUnits(double amount) {
    if (!amount.isFinite) {
      throw ArgumentError.value(amount, 'amount', 'Must be finite');
    }
    return (amount * 100).round();
  }

  /// Calculates tax on the net amount and rounds half-up to two decimals.
  static double calculate(double netAmount, double ratePercent) {
    if (!netAmount.isFinite || netAmount < 0) {
      throw ArgumentError.value(
        netAmount,
        'netAmount',
        'Must be finite and non-negative',
      );
    }
    if (!isValidRate(ratePercent)) {
      throw ArgumentError.value(
        ratePercent,
        'ratePercent',
        'Must be between 0 and 100',
      );
    }

    final netMinorUnits = toMinorUnits(netAmount);
    final taxMinorUnits = (netMinorUnits * ratePercent / 100).round();
    return taxMinorUnits / 100;
  }
}
