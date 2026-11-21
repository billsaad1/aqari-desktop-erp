import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:app/models/income_expense_report_model.dart';
import 'package:app/models/trial_balance_report_model.dart';
import 'package:app/services/report_export_service.dart';
import 'package:excel_community/excel_community.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final service = ReportExportService();

  TrialBalanceReport trialBalance() => TrialBalanceReport(
    startDate: '2026-01-01',
    endDate: '2026-01-31',
    currency: 'SAR',
    rows: const [
      TrialBalanceRow(
        accountId: 4,
        accountCode: '4101',
        accountName: '=1+1',
        accountType: 'Revenue',
        openingDebitMinor: 500,
        openingCreditMinor: 0,
        periodDebitMinor: 0,
        periodCreditMinor: 1250,
        closingDebitMinor: 0,
        closingCreditMinor: 750,
      ),
    ],
  );

  test('CSV is UTF-8 BOM, CRLF, quotes text, and neutralizes formula text', () {
    final data = ReportExportData.trialBalance(trialBalance());
    final bytes = service.encodeCsv(data);
    expect(bytes.take(3).toList(), [0xef, 0xbb, 0xbf]);
    expect(
      data.metadataRows.singleWhere(
        (row) => row.first == 'إجمالي الافتتاحي مدين',
      ),
      ['إجمالي الافتتاحي مدين', 5.0, 'إجمالي الافتتاحي دائن', 0.0],
    );

    final csv = utf8.decode(bytes);
    expect(csv, contains('\r\n'));
    expect(csv, contains('"\'=1+1"'));
    expect(csv, contains('12.50'));
    expect(csv, contains('2026-01-01'));
  });

  test('XLSX uses Arabic RTL sheet, typed dates and numeric money cells', () {
    final data = ReportExportData.trialBalance(trialBalance());
    final bytes = service.encodeXlsx(data);
    final workbook = Excel.decodeBytes(bytes);
    final sheet = workbook.tables['ميزان المراجعة'];
    final worksheet = ZipDecoder()
        .decodeBytes(bytes)
        .findFile('xl/worksheets/sheet1.xml');

    expect(sheet, isNotNull);
    expect(worksheet, isNotNull);
    expect(
      utf8.decode(worksheet!.content as List<int>),
      contains('rightToLeft="1"'),
    );
    expect(sheet!.isRTL, isTrue);
    expect(
      sheet.cell(CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: 1)).value,
      isA<DateCellValue>(),
    );

    final amount = sheet
        .cell(
          CellIndex.indexByColumnRow(
            columnIndex: 6,
            rowIndex: data.metadataRows.length + 2,
          ),
        )
        .value;
    expect(amount, isA<DoubleCellValue>());
    expect((amount! as DoubleCellValue).value, 12.5);

    final text = sheet
        .cell(
          CellIndex.indexByColumnRow(
            columnIndex: 1,
            rowIndex: data.metadataRows.length + 2,
          ),
        )
        .value;
    expect(text, isA<TextCellValue>());
    expect((text! as TextCellValue).value.text, '=1+1');
  });

  test('income and expense export keeps the selected cost-center rows', () {
    const selected = IncomeExpenseAccountRow(
      accountId: 1,
      accountCode: '4101',
      accountName: 'إيراد إيجار',
      accountType: 'Revenue',
      debitMinor: 0,
      creditMinor: 8000,
      costCenterId: 10,
      costCenterCode: 'CC-A',
      costCenterName: 'مركز أ',
    );
    const excluded = IncomeExpenseAccountRow(
      accountId: 2,
      accountCode: '5101',
      accountName: 'مصروف صيانة',
      accountType: 'Expense',
      debitMinor: 2500,
      creditMinor: 0,
      costCenterId: 20,
      costCenterCode: 'CC-B',
      costCenterName: 'مركز ب',
    );
    final unfiltered = IncomeExpenseReport(
      startDate: '2026-01-01',
      endDate: '2026-01-31',
      currency: 'SAR',
      costCenters: const [
        IncomeExpenseCostCenter(id: 10, code: 'CC-A', name: 'مركز أ'),
        IncomeExpenseCostCenter(id: 20, code: 'CC-B', name: 'مركز ب'),
      ],
      rows: const [selected, excluded],
    );
    final filtered = unfiltered.withCostCenterFilter(
      filteredRows: const [selected],
      filterKey: 'center:10',
      filterLabel: 'CC-A - مركز أ',
    );

    final data = ReportExportData.incomeExpense(filtered);
    expect(data.rows, hasLength(1));
    expect(data.rows.single[3], 'إيراد إيجار');
    expect(data.rows.single[1], 'CC-A - مركز أ');
    expect(data.metadataRows[3][1], 'CC-A - مركز أ');
    expect(data.rows.single[5], 80.0);
    expect(
      data.metadataRows.singleWhere((row) => row.first == 'مدين الإيرادات'),
      ['مدين الإيرادات', 0.0, 'دائن الإيرادات', 80.0],
    );
    expect(
      data.metadataRows.singleWhere((row) => row.first == 'مدين المصروفات'),
      ['مدين المصروفات', 0.0, 'دائن المصروفات', 0.0],
    );
  });

  test(
    'authorization is checked before and after the save-location picker',
    () async {
      var allowed = false;
      var pickerCalls = 0;
      var writeCalls = 0;
      final guardedService = ReportExportService(
        pickSaveLocation: ({required suggestedName, required extension}) async {
          pickerCalls++;
          return '/tmp/aqari-export';
        },
        writeBytes: (path, bytes) async {
          writeCalls++;
        },
      );
      final data = ReportExportData.trialBalance(trialBalance());

      final deniedBeforePicker = await guardedService.exportReport(
        data: data,
        format: ReportExportFormat.csv,
        isAuthorized: () => allowed,
      );
      expect(deniedBeforePicker.status, ReportExportStatus.permissionDenied);
      expect(pickerCalls, 0);
      expect(writeCalls, 0);

      allowed = true;
      final deniedAfterPicker = await guardedService.exportReport(
        data: data,
        format: ReportExportFormat.csv,
        isAuthorized: () => pickerCalls == 0,
      );
      expect(deniedAfterPicker.status, ReportExportStatus.permissionDenied);
      expect(pickerCalls, 1);
      expect(writeCalls, 0);
    },
  );

  test('canceling the picker does not write a file', () async {
    var writeCalls = 0;
    final cancelService = ReportExportService(
      pickSaveLocation: ({required suggestedName, required extension}) async =>
          null,
      writeBytes: (path, bytes) async {
        writeCalls++;
      },
    );

    final result = await cancelService.exportReport(
      data: ReportExportData.trialBalance(trialBalance()),
      format: ReportExportFormat.xlsx,
      isAuthorized: () => true,
    );

    expect(result.status, ReportExportStatus.cancelled);
    expect(writeCalls, 0);
  });

  test('successful export appends the selected format extension', () async {
    String? writtenPath;
    Uint8List? writtenBytes;
    final saveService = ReportExportService(
      pickSaveLocation: ({required suggestedName, required extension}) async {
        expect(suggestedName, endsWith('.xlsx'));
        expect(extension, 'xlsx');
        return '/tmp/aqari-report';
      },
      writeBytes: (path, bytes) async {
        writtenPath = path;
        writtenBytes = bytes;
      },
    );

    final result = await saveService.exportReport(
      data: ReportExportData.trialBalance(trialBalance()),
      format: ReportExportFormat.xlsx,
      isAuthorized: () => true,
    );

    expect(result.status, ReportExportStatus.saved);
    expect(result.path, '/tmp/aqari-report.xlsx');
    expect(writtenPath, result.path);
    expect(writtenBytes, isNotEmpty);
  });
}
