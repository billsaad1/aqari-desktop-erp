class AccountStatementLine {
  const AccountStatementLine({
    required this.date,
    required this.journalEntryId,
    required this.description,
    required this.debit,
    required this.credit,
    required this.runningBalance,
  });

  final String date;
  final int journalEntryId;
  final String description;
  final double debit;
  final double credit;
  final double runningBalance;
}

class AccountStatementReport {
  AccountStatementReport({
    required this.accountId,
    required this.accountCode,
    required this.accountName,
    required this.accountType,
    required this.currency,
    required this.startDate,
    required this.endDate,
    required this.openingBalance,
    required this.totalDebit,
    required this.totalCredit,
    required this.closingBalance,
    required List<AccountStatementLine> lines,
  }) : lines = List.unmodifiable(lines);

  final int accountId;
  final String accountCode;
  final String accountName;
  final String accountType;
  final String currency;
  final String startDate;
  final String endDate;
  final double openingBalance;
  final double totalDebit;
  final double totalCredit;
  final double closingBalance;
  final List<AccountStatementLine> lines;

  bool get hasActivity => lines.isNotEmpty;

  AccountStatementReport forSelectedPeriodOnly() => AccountStatementReport(
    accountId: accountId,
    accountCode: accountCode,
    accountName: accountName,
    accountType: accountType,
    currency: currency,
    startDate: startDate,
    endDate: endDate,
    openingBalance: 0,
    totalDebit: totalDebit,
    totalCredit: totalCredit,
    closingBalance: closingBalance - openingBalance,
    lines: lines
        .map(
          (line) => AccountStatementLine(
            date: line.date,
            journalEntryId: line.journalEntryId,
            description: line.description,
            debit: line.debit,
            credit: line.credit,
            runningBalance: line.runningBalance - openingBalance,
          ),
        )
        .toList(growable: false),
  );
}
