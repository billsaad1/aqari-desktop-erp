import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:excel_community/excel_community.dart';
import 'package:file_selector/file_selector.dart';

import '../core/print_utils.dart';
import '../models/financial_position_report_model.dart';
import '../models/income_expense_report_model.dart';
import '../models/trial_balance_report_model.dart';

enum ReportExportFormat { csv, xlsx }

enum ReportExportStatus { saved, cancelled, permissionDenied }

extension ReportExportFormatDetails on ReportExportFormat {
  String get fileExtension => switch (this) {
    ReportExportFormat.csv => 'csv',
    ReportExportFormat.xlsx => 'xlsx',
  };

  String get label => switch (this) {
    ReportExportFormat.csv => 'CSV',
    ReportExportFormat.xlsx => 'Excel',
  };
}

class ReportExportResult {
  const ReportExportResult(this.status, {this.path});

  final ReportExportStatus status;
  final String? path;
}

typedef ReportSaveLocationPicker =
    Future<String?> Function({
      required String suggestedName,
      required String extension,
    });
typedef ReportBytesWriter = Future<void> Function(String path, Uint8List bytes);

class ReportExportData {
  ReportExportData({
    required this.title,
    required this.sheetName,
    required this.fileName,
    required List<List<Object?>> metadataRows,
    required List<String> headers,
    required List<List<Object?>> rows,
  }) : metadataRows = _freezeRows(metadataRows),
       headers = List.unmodifiable(headers),
       rows = _freezeRows(rows) {
    if (this.headers.isEmpty) {
      throw ArgumentError.value(headers, 'headers', 'يلزم عمود واحد على الأقل');
    }
    if (sheetName.isEmpty ||
        sheetName.length > 31 ||
        RegExp(r'[\\/*?:\[\]]').hasMatch(sheetName)) {
      throw ArgumentError.value(
        sheetName,
        'sheetName',
        'اسم ورقة Excel غير صالح',
      );
    }
    if (this.metadataRows.any((row) => row.length > this.headers.length)) {
      throw ArgumentError.value(
        metadataRows,
        'metadataRows',
        'لا يجوز أن يتجاوز صف البيانات التمهيدية عدد الأعمدة',
      );
    }
    if (this.rows.any((row) => row.length != this.headers.length)) {
      throw ArgumentError.value(
        rows,
        'rows',
        'يجب أن يتطابق عدد خلايا كل صف مع عدد العناوين',
      );
    }
  }

  final String title;
  final String sheetName;
  final String fileName;
  final List<List<Object?>> metadataRows;
  final List<String> headers;
  final List<List<Object?>> rows;

  factory ReportExportData.trialBalance(TrialBalanceReport report) {
    final currency = PrintUtils.currencyInArabic(report.currency);
    return ReportExportData(
      title: 'ميزان المراجعة',
      sheetName: 'ميزان المراجعة',
      fileName: 'ميزان_المراجعة_${report.startDate}_${report.endDate}',
      metadataRows: [
        ['التقرير', 'ميزان المراجعة'],
        [
          'من تاريخ',
          _parseIsoDate(report.startDate),
          'إلى تاريخ',
          _parseIsoDate(report.endDate),
        ],
        ['العملة', currency],
        ['وحدة المبالغ', 'العملة الأساسية؛ حُولت من الوحدات الصغرى الصحيحة.'],
        [
          'إجمالي الافتتاحي مدين',
          _majorUnits(report.openingDebitMinor),
          'إجمالي الافتتاحي دائن',
          _majorUnits(report.openingCreditMinor),
        ],
        [
          'إجمالي الحركة مدينة',
          _majorUnits(report.periodDebitMinor),
          'إجمالي الحركة دائنة',
          _majorUnits(report.periodCreditMinor),
        ],
        [
          'إجمالي الختامي مدين',
          _majorUnits(report.closingDebitMinor),
          'إجمالي الختامي دائن',
          _majorUnits(report.closingCreditMinor),
        ],
      ],
      headers: const [
        'رمز الحساب',
        'اسم الحساب',
        'نوع الحساب',
        'افتتاحي مدين',
        'افتتاحي دائن',
        'حركة مدين',
        'حركة دائن',
        'ختامي مدين',
        'ختامي دائن',
      ],
      rows: [
        for (final row in report.rows)
          [
            row.accountCode,
            row.accountName,
            _accountTypeLabel(row.accountType),
            _majorUnits(row.openingDebitMinor),
            _majorUnits(row.openingCreditMinor),
            _majorUnits(row.periodDebitMinor),
            _majorUnits(row.periodCreditMinor),
            _majorUnits(row.closingDebitMinor),
            _majorUnits(row.closingCreditMinor),
          ],
      ],
    );
  }

  factory ReportExportData.financialPosition(FinancialPositionReport report) {
    final currency = PrintUtils.currencyInArabic(report.currency);
    return ReportExportData(
      title: 'قائمة المركز المالي الداخلية',
      sheetName: 'المركز المالي',
      fileName: 'المركز_المالي_${report.asOfDate}',
      metadataRows: [
        ['التقرير', 'قائمة المركز المالي الداخلية'],
        ['حتى تاريخ', _parseIsoDate(report.asOfDate)],
        ['العملة', currency],
        ['الأصول', _majorUnits(report.assetsMinor)],
        ['الخصوم', _majorUnits(report.liabilitiesMinor)],
        ['حقوق الملكية المسجلة', _majorUnits(report.equityAccountsMinor)],
        ['الإيرادات غير المقفلة', _majorUnits(report.revenuesMinor)],
        ['المصروفات غير المقفلة', _majorUnits(report.expensesMinor)],
        ['النتيجة غير المقفلة', _majorUnits(report.unclosedEarningsMinor)],
        ['الخصوم وحقوق الملكية', _majorUnits(report.liabilitiesAndEquityMinor)],
        ['فرق المعادلة', _majorUnits(report.equationDifferenceMinor)],
      ],
      headers: const [
        'التصنيف',
        'رمز الحساب',
        'اسم الحساب',
        'مدين',
        'دائن',
        'الرصيد الطبيعي',
      ],
      rows: [
        for (final row in report.rows)
          [
            row.typeLabel,
            row.accountCode,
            row.accountName,
            _majorUnits(row.debitMinor),
            _majorUnits(row.creditMinor),
            _majorUnits(row.normalBalanceMinor),
          ],
      ],
    );
  }

  factory ReportExportData.incomeExpense(IncomeExpenseReport report) {
    final filterFilePart = report.costCenterFilterKey.replaceAll(
      RegExp(r'[^A-Za-z0-9_-]'),
      '_',
    );
    return ReportExportData(
      title: 'حركة الإيرادات والمصروفات',
      sheetName: 'الإيرادات والمصروفات',
      fileName:
          'حركة_الإيرادات_والمصروفات_${report.startDate}_${report.endDate}_$filterFilePart',
      metadataRows: [
        ['التقرير', 'حركة الإيرادات والمصروفات'],
        [
          'من تاريخ',
          _parseIsoDate(report.startDate),
          'إلى تاريخ',
          _parseIsoDate(report.endDate),
        ],
        ['العملة', PrintUtils.currencyInArabic(report.currency)],
        ['مرشح مركز التكلفة', report.costCenterFilterLabel],
        ['صافي الإيرادات', _majorUnits(report.revenueNetMinor)],
        ['صافي المصروفات', _majorUnits(report.expenseNetMinor)],
        ['صافي نتيجة الفترة', _majorUnits(report.netResultMinor)],
        [
          'مدين الإيرادات',
          _majorUnits(report.revenueDebitMinor),
          'دائن الإيرادات',
          _majorUnits(report.revenueCreditMinor),
        ],
        [
          'مدين المصروفات',
          _majorUnits(report.expenseDebitMinor),
          'دائن المصروفات',
          _majorUnits(report.expenseCreditMinor),
        ],
        ['وحدة المبالغ', 'العملة الأساسية؛ حُولت من الوحدات الصغرى الصحيحة.'],
      ],
      headers: const [
        'النوع',
        'مركز التكلفة',
        'رمز الحساب',
        'اسم الحساب',
        'مدين',
        'دائن',
        'الصافي',
      ],
      rows: [
        for (final row in report.rows)
          [
            row.accountType == 'Revenue' ? 'إيراد' : 'مصروف',
            row.costCenterLabel,
            row.accountCode,
            row.accountName,
            _majorUnits(row.debitMinor),
            _majorUnits(row.creditMinor),
            _majorUnits(row.netMinor),
          ],
      ],
    );
  }
}

class ReportExportService {
  ReportExportService({
    ReportSaveLocationPicker? pickSaveLocation,
    ReportBytesWriter? writeBytes,
  }) : _pickSaveLocation = pickSaveLocation ?? _defaultPickSaveLocation,
       _writeBytes = writeBytes ?? _defaultWriteBytes;

  final ReportSaveLocationPicker _pickSaveLocation;
  final ReportBytesWriter _writeBytes;

  Uint8List encodeCsv(ReportExportData data) {
    final rows = _completeRows(data);
    final body = rows.map(_encodeCsvRow).join('\r\n');
    return Uint8List.fromList(utf8.encode('\uFEFF$body\r\n'));
  }

  Uint8List encodeXlsx(ReportExportData data) {
    final workbook = Excel.createExcel();
    final defaultSheet = workbook.getDefaultSheet();
    if (defaultSheet == null) {
      throw StateError('تعذر إنشاء ورقة Excel افتراضية');
    }
    workbook.rename(defaultSheet, data.sheetName);
    final sheet = workbook[data.sheetName];
    // Register the new sheet's XML before setting properties; the package
    // parser otherwise applies its default sheet view during the first save.
    final bootstrapBytes = workbook.save();
    if (bootstrapBytes == null || bootstrapBytes.isEmpty) {
      throw StateError('تعذر تهيئة ورقة Excel');
    }
    sheet.isRTL = true;

    final rows = _completeRows(data);
    final headerRowIndex = data.metadataRows.length + 1;
    for (var rowIndex = 0; rowIndex < rows.length; rowIndex++) {
      final row = rows[rowIndex];
      for (var columnIndex = 0; columnIndex < row.length; columnIndex++) {
        final value = row[columnIndex];
        final cell = sheet.cell(
          CellIndex.indexByColumnRow(
            columnIndex: columnIndex,
            rowIndex: rowIndex,
          ),
        );
        if (value == null) {
          cell.value = null;
        } else if (value is String) {
          cell.value = TextCellValue(value);
        } else if (value is int) {
          cell.value = IntCellValue(value);
        } else if (value is double) {
          if (!value.isFinite) {
            throw ArgumentError.value(
              value,
              'value',
              'يجب أن يكون الرقم محدودًا',
            );
          }
          cell.value = DoubleCellValue(value);
          cell.cellStyle = CellStyle(
            numberFormat: CustomNumericNumFormat(
              formatCode: '#,##0.00;(#,##0.00)',
            ),
          );
        } else if (value is DateTime) {
          cell.value = DateCellValue(
            year: value.year,
            month: value.month,
            day: value.day,
          );
          cell.cellStyle = CellStyle(
            numberFormat: CustomDateTimeNumFormat(formatCode: 'yyyy-mm-dd'),
          );
        } else if (value is bool) {
          cell.value = BoolCellValue(value);
        } else {
          throw ArgumentError.value(
            value,
            'value',
            'نوع قيمة غير مدعوم في التصدير',
          );
        }

        if (rowIndex == headerRowIndex && value is String) {
          cell.cellStyle = CellStyle(bold: true);
        }
      }
    }

    final bytes = workbook.save();
    if (bytes == null || bytes.isEmpty) {
      throw StateError('تعذر إنشاء محتوى ملف Excel');
    }
    return Uint8List.fromList(bytes);
  }

  Future<ReportExportResult> exportReport({
    required ReportExportData data,
    required ReportExportFormat format,
    required bool Function() isAuthorized,
  }) async {
    if (!isAuthorized()) {
      return const ReportExportResult(ReportExportStatus.permissionDenied);
    }

    final bytes = switch (format) {
      ReportExportFormat.csv => encodeCsv(data),
      ReportExportFormat.xlsx => encodeXlsx(data),
    };
    if (!isAuthorized()) {
      return const ReportExportResult(ReportExportStatus.permissionDenied);
    }

    final suggestedName = '${data.fileName}.${format.fileExtension}';
    final selectedPath = await _pickSaveLocation(
      suggestedName: suggestedName,
      extension: format.fileExtension,
    );
    if (selectedPath == null) {
      return const ReportExportResult(ReportExportStatus.cancelled);
    }
    if (!isAuthorized()) {
      return const ReportExportResult(ReportExportStatus.permissionDenied);
    }

    final path = _ensureExtension(selectedPath, format.fileExtension);
    await _writeBytes(path, bytes);
    return ReportExportResult(ReportExportStatus.saved, path: path);
  }

  List<List<Object?>> _completeRows(ReportExportData data) {
    final width = data.headers.length;
    final result = <List<Object?>>[];
    for (final row in data.metadataRows) {
      result.add([...row, ...List<Object?>.filled(width - row.length, null)]);
    }
    result.add(List<Object?>.filled(width, null));
    result.add(data.headers.map<Object?>((value) => value).toList());
    result.addAll(data.rows);
    return result;
  }

  String _encodeCsvRow(List<Object?> row) => row.map(_encodeCsvField).join(',');

  String _encodeCsvField(Object? value) {
    if (value == null) return '';
    if (value is int) return value.toString();
    if (value is double) {
      if (!value.isFinite) {
        throw ArgumentError.value(value, 'value', 'يجب أن يكون الرقم محدودًا');
      }
      return value.toStringAsFixed(2);
    }
    if (value is bool) return value ? 'TRUE' : 'FALSE';

    final text = value is DateTime ? _isoDate(value) : value.toString();
    final safeText = value is String && _startsWithFormulaMarker(text)
        ? "'$text"
        : text;
    return '"${safeText.replaceAll('"', '""')}"';
  }
}

List<List<Object?>> _freezeRows(List<List<Object?>> rows) =>
    List.unmodifiable(rows.map((row) => List<Object?>.unmodifiable(row)));

double _majorUnits(int minorUnits) => minorUnits / 100.0;

DateTime _parseIsoDate(String value) {
  final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(value);
  if (match == null) {
    throw FormatException('التاريخ ليس بصيغة yyyy-MM-dd', value);
  }
  final year = int.parse(match.group(1)!);
  final month = int.parse(match.group(2)!);
  final day = int.parse(match.group(3)!);
  final parsed = DateTime.utc(year, month, day);
  if (parsed.year != year || parsed.month != month || parsed.day != day) {
    throw FormatException('التاريخ غير تقويمي', value);
  }
  return parsed;
}

String _isoDate(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';

String _accountTypeLabel(String type) => switch (type) {
  'Asset' => 'أصول',
  'Liability' => 'خصوم',
  'Equity' => 'حقوق ملكية',
  'Revenue' => 'إيرادات',
  'Expense' => 'مصروفات',
  _ => 'غير مصنف',
};

bool _startsWithFormulaMarker(String value) {
  for (var index = 0; index < value.length; index++) {
    final codeUnit = value.codeUnitAt(index);
    if (codeUnit == 0xfeff || codeUnit <= 0x20) continue;
    return codeUnit == 0x3d || // =
        codeUnit == 0x2b || // +
        codeUnit == 0x2d || // -
        codeUnit == 0x40; // @
  }
  return false;
}

Future<String?> _defaultPickSaveLocation({
  required String suggestedName,
  required String extension,
}) async {
  final location = await getSaveLocation(
    suggestedName: suggestedName,
    acceptedTypeGroups: [
      XTypeGroup(label: extension.toUpperCase(), extensions: [extension]),
    ],
  );
  return location?.path;
}

Future<void> _defaultWriteBytes(String path, Uint8List bytes) =>
    File(path).writeAsBytes(bytes, flush: true);

String _ensureExtension(String path, String extension) =>
    path.toLowerCase().endsWith('.$extension') ? path : '$path.$extension';
