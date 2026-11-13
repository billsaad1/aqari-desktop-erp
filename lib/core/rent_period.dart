/// Stable storage keys and Arabic labels for unit rent cadence.
class RentPeriod {
  RentPeriod._();

  static const monthly = 'monthly';
  static const annual = 'annual';

  static const values = [monthly, annual];

  static bool isValid(Object? value) => values.contains(value);

  static String? label(Object? value) {
    return switch (value) {
      monthly => 'شهرياً',
      annual => 'سنوياً',
      _ => null,
    };
  }
}
