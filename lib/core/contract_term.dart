/// Calendar-month rules for rental contracts.
///
/// Contract end dates are inclusive. A non-month-end term ends the day before
/// the next clamped monthly anniversary. When a term starts at month-end and
/// the anniversary is clamped to a shorter month (or is a non-annual month-end
/// term), the target month-end is accepted as the full-period end.
class ContractTerm {
  ContractTerm._();

  static const int maxMonths = 600;

  static DateTime addMonthsClamped(DateTime date, int months) {
    final firstOfMonth = DateTime(date.year, date.month + months, 1);
    final lastDay = DateTime(firstOfMonth.year, firstOfMonth.month + 1, 0).day;
    return DateTime(
      firstOfMonth.year,
      firstOfMonth.month,
      date.day > lastDay ? lastDay : date.day,
    );
  }

  static DateTime endDateForMonths(DateTime start, int months) {
    if (months < 1 || months > maxMonths) {
      throw ArgumentError.value(months, 'months', 'مدة العقد غير صحيحة');
    }
    final startDate = _dateOnly(start);
    final anniversary = addMonthsClamped(startDate, months);
    final startAtMonthEnd = _isMonthEnd(startDate);
    final anniversaryWasClamped = anniversary.day != startDate.day;

    if (startAtMonthEnd && (months % 12 != 0 || anniversaryWasClamped)) {
      return _monthEnd(anniversary);
    }
    return anniversary.subtract(const Duration(days: 1));
  }

  /// Returns the whole number of monthly periods represented by an inclusive
  /// date range, or null when it contains a partial month/day span.
  static int? wholeMonths(DateTime start, DateTime inclusiveEnd) {
    final startDate = _dateOnly(start);
    final endDate = _dateOnly(inclusiveEnd);
    if (endDate.isBefore(startDate)) return null;

    for (var months = 1; months <= maxMonths; months++) {
      final expectedEnd = endDateForMonths(startDate, months);
      if (_sameDate(expectedEnd, endDate)) return months;
      if (expectedEnd.isAfter(endDate)) return null;
    }
    return null;
  }

  /// The first day after the inclusive end of a whole-period contract.
  static DateTime nextStartDate(DateTime start, DateTime inclusiveEnd) {
    if (wholeMonths(start, inclusiveEnd) == null) {
      throw ArgumentError(
        'مدة العقد يجب أن تكون شهرًا أو عددًا صحيحًا من الشهور',
      );
    }
    return _dateOnly(inclusiveEnd).add(const Duration(days: 1));
  }

  /// Whole-month coverage for each installment according to the payment
  /// cadence. A final short billing period remains a full number of months.
  static List<int> paymentMonthWeights(
    int durationMonths,
    String paymentMethod,
  ) {
    if (durationMonths < 1 || durationMonths > maxMonths) {
      throw ArgumentError.value(
        durationMonths,
        'durationMonths',
        'مدة العقد غير صحيحة',
      );
    }
    final monthsPerInstallment = switch (paymentMethod) {
      'شهري' => 1,
      'ربع سنوي' => 3,
      'نصف سنوي' => 6,
      'سنوي' => 12,
      'دفعة واحدة' => durationMonths,
      _ => throw ArgumentError.value(
        paymentMethod,
        'paymentMethod',
        'طريقة الدفع غير معروفة',
      ),
    };

    final weights = <int>[];
    var remaining = durationMonths;
    while (remaining > 0) {
      final coveredMonths = remaining < monthsPerInstallment
          ? remaining
          : monthsPerInstallment;
      weights.add(coveredMonths);
      remaining -= coveredMonths;
    }
    return weights;
  }

  /// Allocates a contract total in minor units proportional to whole months.
  /// Rounding residue is assigned to the last installment so the sum is exact.
  static List<int> allocateMinorUnits(int totalMinor, List<int> weights) {
    if (totalMinor <= 0 || weights.isEmpty || weights.any((w) => w <= 0)) {
      throw ArgumentError('قيمة العقد أو أوزان الأقساط غير صحيحة');
    }
    final totalMonths = weights.fold<int>(0, (sum, weight) => sum + weight);
    final amounts = <int>[];
    var allocated = 0;
    for (var i = 0; i < weights.length; i++) {
      final amount = i == weights.length - 1
          ? totalMinor - allocated
          : (totalMinor * weights[i] + totalMonths ~/ 2) ~/ totalMonths;
      if (amount <= 0) {
        throw ArgumentError('إجمالي العقد لا يكفي لإنشاء أقساط موجبة');
      }
      amounts.add(amount);
      allocated += amount;
    }
    return amounts;
  }

  static DateTime _dateOnly(DateTime value) =>
      DateTime(value.year, value.month, value.day);

  static DateTime _monthEnd(DateTime value) =>
      DateTime(value.year, value.month + 1, 0);

  static bool _isMonthEnd(DateTime value) => value.day == _monthEnd(value).day;

  static bool _sameDate(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}
