import "../../core/print_utils.dart";
import '../../core/pdf_preview_dialog.dart';
import 'package:flutter/material.dart';
import '../../core/erp_data_table.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import '../../providers/reports_provider.dart';
import '../../providers/accounting_provider.dart';
import '../../database/database_helper.dart';

class AccountStatementScreen extends StatefulWidget {
  const AccountStatementScreen({super.key});

  @override
  State<AccountStatementScreen> createState() => _AccountStatementScreenState();
}

class _AccountStatementScreenState extends State<AccountStatementScreen> {
  final _startDateController = TextEditingController(
    text: DateFormat(
      'yyyy-MM-dd',
    ).format(DateTime.now().subtract(const Duration(days: 30))),
  );
  final _endDateController = TextEditingController(
    text: DateFormat('yyyy-MM-dd').format(DateTime.now()),
  );
  int? _selectedAccountId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Provider.of<AccountingProvider>(context, listen: false).loadAccounts();
    });
  }

  void _loadStatement() {
    if (_selectedAccountId != null) {
      final start = DateTime.tryParse(_startDateController.text);
      final end = DateTime.tryParse(_endDateController.text);
      if (start == null || end == null || start.isAfter(end)) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تحقق من صحة الفترة الزمنية')),
        );
        return;
      }
      Provider.of<ReportsProvider>(context, listen: false).loadAccountStatement(
        _selectedAccountId!,
        _startDateController.text,
        _endDateController.text,
      );
    }
  }

  Future<void> _selectDate(TextEditingController controller) async {
    final initial = DateTime.tryParse(controller.text) ?? DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null && mounted) {
      setState(() => controller.text = DateFormat('yyyy-MM-dd').format(picked));
    }
  }

  Future<void> _printStatement(
    List<Map<String, dynamic>> statement,
    String accountName,
    String accountType,
    double openingBalance, {
    required bool saveAsPdf,
  }) async {
    try {
      final companyInfo = await DatabaseHelper.instance.getCompanyInfo();
      final currency = PrintUtils.currencyInArabic(
        companyInfo?['default_currency'],
      );
      final pdf = pw.Document();
      final theme = await PrintUtils.loadArabicTheme();
      final debitNormal = accountType == 'Asset' || accountType == 'Expense';
      var runningBalance = openingBalance;
      final tableData = statement.map((s) {
        final debit = (s['debit'] as num).toDouble();
        final credit = (s['credit'] as num).toDouble();
        runningBalance += debitNormal ? debit - credit : credit - debit;
        return [
          s['date'].toString(),
          s['voucher_no'].toString(),
          s['description']?.toString() ?? '',
          PrintUtils.formatPdfAmount(debit),
          PrintUtils.formatPdfAmount(credit),
          PrintUtils.formatPdfAmount(runningBalance),
        ];
      }).toList();
      final closingBalance = runningBalance;
      final accountTypeArabic = switch (accountType) {
        'Asset' => 'أصول',
        'Liability' => 'التزامات',
        'Equity' => 'حقوق ملكية',
        'Revenue' => 'إيرادات',
        'Expense' => 'مصروفات',
        _ => accountType,
      };

      pdf.addPage(
        pw.MultiPage(
          pageTheme: PrintUtils.pageTheme(
            theme: theme,
            companyInfo: companyInfo,
            margin: const pw.EdgeInsets.fromLTRB(32, 30, 32, 34),
          ),
          header: (_) => PrintUtils.buildHeader(companyInfo, true),
          footer: (context) => PrintUtils.buildPageFooter(context, companyInfo),
          build: (_) => [
            pw.Center(
              child: pw.Text(
                'كشف حساب تفصيلي',
                textDirection: pw.TextDirection.rtl,
                textAlign: pw.TextAlign.center,
                style: pw.TextStyle(
                  fontSize: 17,
                  fontWeight: pw.FontWeight.bold,
                  color: PrintUtils.brandNavy,
                ),
              ),
            ),
            pw.SizedBox(height: 8),
            pw.Container(
              padding: const pw.EdgeInsets.all(10),
              decoration: pw.BoxDecoration(
                color: PrintUtils.softSurface,
                border: pw.Border.all(color: PrintUtils.softBorder),
                borderRadius: pw.BorderRadius.circular(5),
              ),
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.stretch,
                children: [
                  PrintUtils.buildLabelValue(
                    'الحساب',
                    accountName,
                    labelWidth: 76,
                  ),
                  pw.Row(
                    children: [
                      pw.Expanded(
                        child: PrintUtils.buildLabelValue(
                          'نوع الحساب',
                          accountTypeArabic,
                          labelWidth: 76,
                        ),
                      ),
                      pw.SizedBox(width: 12),
                      pw.Expanded(
                        child: PrintUtils.buildLabelValue(
                          'العملة',
                          currency,
                          labelWidth: 55,
                        ),
                      ),
                    ],
                  ),
                  pw.Row(
                    children: [
                      pw.Expanded(
                        child: PrintUtils.buildLabelValue(
                          'من تاريخ',
                          _startDateController.text,
                          valueDirection: pw.TextDirection.ltr,
                          labelWidth: 76,
                        ),
                      ),
                      pw.SizedBox(width: 12),
                      pw.Expanded(
                        child: PrintUtils.buildLabelValue(
                          'إلى تاريخ',
                          _endDateController.text,
                          valueDirection: pw.TextDirection.ltr,
                          labelWidth: 76,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            pw.SizedBox(height: 8),
            pw.Container(
              padding: const pw.EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 7,
              ),
              decoration: pw.BoxDecoration(
                border: pw.Border.all(color: PrintUtils.softBorder),
                borderRadius: pw.BorderRadius.circular(5),
              ),
              child: pw.Row(
                children: [
                  pw.Expanded(
                    child: PrintUtils.buildLabelValue(
                      'الرصيد الافتتاحي',
                      PrintUtils.formatPdfAmount(openingBalance),
                      valueDirection: pw.TextDirection.ltr,
                      labelWidth: 110,
                    ),
                  ),
                  pw.Expanded(
                    child: PrintUtils.buildLabelValue(
                      'الرصيد الختامي',
                      PrintUtils.formatPdfAmount(closingBalance),
                      valueDirection: pw.TextDirection.ltr,
                      labelWidth: 110,
                    ),
                  ),
                ],
              ),
            ),
            pw.SizedBox(height: 12),
            pw.TableHelper.fromTextArray(
              headers: [
                'التاريخ',
                'رقم القيد',
                'البيان',
                'مدين',
                'دائن',
                'الرصيد',
              ],
              data: tableData,
              headerStyle: pw.TextStyle(
                fontSize: 9,
                fontWeight: pw.FontWeight.bold,
                color: PdfColors.white,
              ),
              headerDecoration: pw.BoxDecoration(color: PrintUtils.brandNavy),
              cellStyle: const pw.TextStyle(fontSize: 8.5, lineSpacing: 2),
              cellPadding: const pw.EdgeInsets.symmetric(
                horizontal: 4,
                vertical: 6,
              ),
              tableDirection: pw.TextDirection.rtl,
              headerDirection: pw.TextDirection.rtl,
              columnWidths: const {
                0: pw.FixedColumnWidth(65),
                1: pw.FixedColumnWidth(54),
                2: pw.FlexColumnWidth(2.5),
                3: pw.FixedColumnWidth(65),
                4: pw.FixedColumnWidth(65),
                5: pw.FixedColumnWidth(75),
              },
              border: pw.TableBorder.all(
                color: PrintUtils.softBorder,
                width: 0.5,
              ),
              cellAlignments: {
                0: pw.Alignment.center,
                1: pw.Alignment.center,
                2: pw.Alignment.centerRight,
                3: pw.Alignment.center,
                4: pw.Alignment.center,
                5: pw.Alignment.center,
              },
            ),
            if (statement.isEmpty)
              pw.Padding(
                padding: const pw.EdgeInsets.all(12),
                child: pw.Text(
                  'لا توجد حركات خلال الفترة المحددة.',
                  textDirection: pw.TextDirection.rtl,
                  textAlign: pw.TextAlign.center,
                  style: const pw.TextStyle(color: PdfColors.grey700),
                ),
              ),
          ],
        ),
      );

      final bytes = await pdf.save();
      if (mounted) {
        await PdfDocumentPreviewDialog.show(
          context: context,
          bytes: bytes,
          fileName: 'كشف_حساب_${accountName}',
          preferredIntent: saveAsPdf
              ? PdfPreviewIntent.save
              : PdfPreviewIntent.printDocument,
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تعذر تجهيز/طباعة كشف الحساب: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer2<ReportsProvider, AccountingProvider>(
      builder: (context, reportsProv, accProv, child) {
        if (accProv.isLoading)
          return const Center(child: CircularProgressIndicator());

        Map<String, dynamic>? selectedAccount;
        for (final account in accProv.accounts) {
          if (account['id'] == _selectedAccountId) selectedAccount = account;
        }
        final accountName = selectedAccount?['name']?.toString() ?? '';
        final accountType =
            selectedAccount?['account_type']?.toString() ?? 'Asset';
        var runningBalance = reportsProv.accountOpeningBalance;

        return Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'كشف الحساب التفصيلي',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: DropdownButtonFormField<int>(
                      value: _selectedAccountId,
                      items: accProv.accounts
                          .map(
                            (a) => DropdownMenuItem<int>(
                              value: a['id'],
                              child: Text('${a['code']} - ${a['name']}'),
                            ),
                          )
                          .toList(),
                      onChanged: (val) =>
                          setState(() => _selectedAccountId = val),
                      decoration: const InputDecoration(
                        labelText: 'اختر الحساب',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    flex: 1,
                    child: TextFormField(
                      controller: _startDateController,
                      decoration: const InputDecoration(
                        labelText: 'من تاريخ',
                        border: OutlineInputBorder(),
                      ),
                      readOnly: true,
                      onTap: () => _selectDate(_startDateController),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    flex: 1,
                    child: TextFormField(
                      controller: _endDateController,
                      decoration: const InputDecoration(
                        labelText: 'إلى تاريخ',
                        border: OutlineInputBorder(),
                      ),
                      readOnly: true,
                      onTap: () => _selectDate(_endDateController),
                    ),
                  ),
                  const SizedBox(width: 16),
                  ElevatedButton(
                    onPressed: _selectedAccountId != null
                        ? _loadStatement
                        : null,
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.all(20),
                    ),
                    child: const Text('عرض الكشف'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    onPressed: reportsProv.accountStatement.isNotEmpty
                        ? () => _printStatement(
                            reportsProv.accountStatement,
                            accountName,
                            accountType,
                            reportsProv.accountOpeningBalance,
                            saveAsPdf: false,
                          )
                        : null,
                    icon: const Icon(Icons.print),
                    label: const Text('طباعة'),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.all(20),
                      backgroundColor: Colors.orange,
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: reportsProv.accountStatement.isNotEmpty
                        ? () => _printStatement(
                            reportsProv.accountStatement,
                            accountName,
                            accountType,
                            reportsProv.accountOpeningBalance,
                            saveAsPdf: true,
                          )
                        : null,
                    icon: const Icon(Icons.picture_as_pdf),
                    label: const Text('حفظ PDF'),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              if (reportsProv.isLoading)
                const Center(child: CircularProgressIndicator())
              else if (reportsProv.accountStatement.isEmpty)
                const Center(child: Text('لا توجد حركات في هذه الفترة'))
              else
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          'الرصيد الافتتاحي: ${reportsProv.accountOpeningBalance.toStringAsFixed(2)}',
                        ),
                      ),
                      Expanded(
                        child: SingleChildScrollView(
                          child: ErpDataTable(
                            columns: const [
                              DataColumn(label: Text('التاريخ')),
                              DataColumn(label: Text('رقم القيد/السند')),
                              DataColumn(label: Text('البيان')),
                              DataColumn(label: Text('مدين')),
                              DataColumn(label: Text('دائن')),
                              DataColumn(label: Text('الرصيد التراكمي')),
                            ],
                            rows: [
                              DataRow(
                                cells: [
                                  const DataCell(Text('')),
                                  const DataCell(Text('')),
                                  const DataCell(Text('الرصيد الافتتاحي')),
                                  const DataCell(Text('')),
                                  const DataCell(Text('')),
                                  DataCell(
                                    Text(
                                      reportsProv.accountOpeningBalance
                                          .toStringAsFixed(2),
                                    ),
                                  ),
                                ],
                              ),
                              ...reportsProv.accountStatement.map((s) {
                                final d = (s['debit'] as num).toDouble();
                                final c = (s['credit'] as num).toDouble();
                                final debitNormal =
                                    accountType == 'Asset' ||
                                    accountType == 'Expense';
                                runningBalance += debitNormal ? d - c : c - d;

                                return DataRow(
                                  cells: [
                                    DataCell(Text(s['date'])),
                                    DataCell(Text(s['voucher_no'].toString())),
                                    DataCell(Text(s['description'] ?? '')),
                                    DataCell(Text(d.toStringAsFixed(2))),
                                    DataCell(Text(c.toStringAsFixed(2))),
                                    DataCell(
                                      Text(runningBalance.toStringAsFixed(2)),
                                    ),
                                  ],
                                );
                              }),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
