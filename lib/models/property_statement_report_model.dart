/// Phase 27: read-only statement of the posted journal lines attributed to a
/// single property.
///
/// Attribution is deliberately strict. A line belongs to a property only when
/// its cost centre is assigned to that property *and* to no other property. A
/// cost centre shared by several properties makes every line on it ambiguous,
/// so those lines are disclosed as exclusions instead of being counted once per
/// property.
enum PropertyStatementGapReason {
  /// The property has no cost centre, so no line can be attributed to it.
  propertyWithoutCostCenter,

  /// The property's cost centre is also assigned to other properties.
  sharedCostCenter,

  /// Posted lines in the period carry no cost centre at all, so no property can
  /// claim them.
  unassignedCostCenter,
}

class PropertyStatementGap {
  const PropertyStatementGap({
    required this.reason,
    required this.lineCount,
    required this.debitMinor,
    required this.creditMinor,
  });

  final PropertyStatementGapReason reason;
  final int lineCount;
  final int debitMinor;
  final int creditMinor;

  bool get hasAmounts => debitMinor != 0 || creditMinor != 0;
}

class PropertyStatementLine {
  const PropertyStatementLine({
    required this.date,
    required this.journalEntryId,
    required this.journalLineId,
    required this.accountCode,
    required this.accountName,
    required this.description,
    required this.debitMinor,
    required this.creditMinor,
    required this.runningBalanceMinor,
  });

  final String date;
  final int journalEntryId;
  final int journalLineId;
  final String accountCode;
  final String accountName;
  final String description;
  final int debitMinor;
  final int creditMinor;
  final int runningBalanceMinor;
}

class PropertyStatementReport {
  PropertyStatementReport({
    required this.propertyId,
    required this.propertyName,
    required this.ownerName,
    required this.costCenterId,
    required this.costCenterCode,
    required this.costCenterName,
    required this.currency,
    required this.startDate,
    required this.endDate,
    required this.openingBalanceMinor,
    required this.totalDebitMinor,
    required this.totalCreditMinor,
    required this.closingBalanceMinor,
    required List<PropertyStatementLine> lines,
    required List<PropertyStatementGap> gaps,
  }) : lines = List.unmodifiable(lines),
       gaps = List.unmodifiable(gaps);

  final int propertyId;
  final String propertyName;
  final String ownerName;
  final int? costCenterId;
  final String costCenterCode;
  final String costCenterName;
  final String currency;
  final String startDate;
  final String endDate;
  final int openingBalanceMinor;
  final int totalDebitMinor;
  final int totalCreditMinor;
  final int closingBalanceMinor;
  final List<PropertyStatementLine> lines;
  final List<PropertyStatementGap> gaps;

  bool get hasCostCenter => costCenterId != null;
  bool get hasActivity => lines.isNotEmpty;
  bool get hasGaps => gaps.isNotEmpty;
}
