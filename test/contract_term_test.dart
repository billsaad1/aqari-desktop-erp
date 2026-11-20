import 'package:app/core/contract_term.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ContractTerm', () {
    test('counts whole inclusive calendar months without day proration', () {
      expect(
        ContractTerm.wholeMonths(DateTime(2026, 11, 10), DateTime(2026, 12, 9)),
        1,
      );
      expect(
        ContractTerm.wholeMonths(DateTime(2026, 11, 10), DateTime(2027, 11, 9)),
        12,
      );
      expect(
        ContractTerm.wholeMonths(
          DateTime(2026, 11, 10),
          DateTime(2026, 12, 10),
        ),
        isNull,
      );
      expect(
        ContractTerm.wholeMonths(DateTime(2026, 11, 10), DateTime(2026, 12, 8)),
        isNull,
      );
    });

    test('uses calendar month-end for a month-end start and leap-day year', () {
      expect(
        ContractTerm.endDateForMonths(DateTime(2026, 1, 31), 1),
        DateTime(2026, 2, 28),
      );
      expect(
        ContractTerm.wholeMonths(DateTime(2026, 1, 31), DateTime(2026, 2, 28)),
        1,
      );
      expect(
        ContractTerm.endDateForMonths(DateTime(2024, 2, 29), 12),
        DateTime(2025, 2, 28),
      );
      expect(
        ContractTerm.wholeMonths(DateTime(2024, 2, 29), DateTime(2025, 2, 28)),
        12,
      );
      expect(
        ContractTerm.nextStartDate(
          DateTime(2026, 1, 31),
          DateTime(2026, 2, 28),
        ),
        DateTime(2026, 3, 1),
      );
    });

    test('weights short final billing periods by months covered', () {
      expect(ContractTerm.paymentMonthWeights(13, 'سنوي'), [12, 1]);
      expect(ContractTerm.paymentMonthWeights(10, 'ربع سنوي'), [3, 3, 3, 1]);
      expect(ContractTerm.paymentMonthWeights(2, 'شهري'), [1, 1]);
      expect(ContractTerm.paymentMonthWeights(2, 'دفعة واحدة'), [2]);
    });

    test('allocates minor units exactly and puts rounding residue last', () {
      expect(ContractTerm.allocateMinorUnits(1301, [12, 1]), [1201, 100]);
      expect(ContractTerm.allocateMinorUnits(100, [1, 1, 1]), [33, 33, 34]);
      expect(
        ContractTerm.allocateMinorUnits(100, [
          3,
          3,
          3,
          1,
        ]).reduce((a, b) => a + b),
        100,
      );
    });

    test('rejects invalid or impossible installment allocations', () {
      expect(
        () => ContractTerm.paymentMonthWeights(0, 'شهري'),
        throwsArgumentError,
      );
      expect(
        () => ContractTerm.allocateMinorUnits(1, [1, 1]),
        throwsArgumentError,
      );
      expect(
        () => ContractTerm.paymentMonthWeights(2, 'كل أسبوع'),
        throwsArgumentError,
      );
    });
  });
}
