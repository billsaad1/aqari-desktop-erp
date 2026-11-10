import "../../core/print_utils.dart";
import 'package:flutter/material.dart';
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
      final currency = companyInfo?['default_currency']?.toString() ?? 'ريال';
      final pdf = pw.Document();
      final theme = await PrintUtils.loadArabicTheme();
      final debitNormal = accountType == 'Asset' || accountType == 'Expense';
      var runningBalance = openingBalance;
      final tableData = <List<String>>[
        ['', '', 'الرصيد الافتتاحي', '', '', openingBalance.toStringAsFixed(2)],
        ...statement.map((s) {
          final debit = (s['debit'] as num).toDouble();
          final credit = (s['credit'] as num).toDouble();
          runningBalance += debitNormal ? debit - credit : credit - debit;
          return [
            s['date'].toString(),
            s['voucher_no'].toString(),
            s['description']?.toString() ?? '',
            debit.toStringAsFixed(2),
            credit.toStringAsFixed(2),
            runningBalance.toStringAsFixed(2),
          ];
        }),
      ];

      pdf.addPage(
        pw.MultiPage(
          pageTheme: pw.PageTheme(
            buildBackground: (pw.Context context) =>
                PrintUtils.buildWatermark(companyInfo),
          ),
          pageFormat: PdfPageFormat.a4,
          textDirection: pw.TextDirection.rtl,
          theme: theme,
          header: (_) => PrintUtils.buildHeader(companyInfo, true),
          footer: (context) => PrintUtils.buildPageFooter(context, companyInfo),
          build: (_) => [
            pw.Center(
              child: pw.Text(
                'كشف حساب تفصيلي',
                textDirection: pw.TextDirection.rtl,
                style: pw.TextStyle(
                  fontSize: 20,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
            ),
            pw.SizedBox(height: 14),
            pw.Text(
              'الحساب: $accountName',
              textDirection: pw.TextDirection.rtl,
              style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold),
            ),
            pw.Text(
              'العملة: $currency',
              textDirection: pw.TextDirection.rtl,
              style: const pw.TextStyle(fontSize: 10),
            ),
            pw.Text(
              'من تاريخ: ${_startDateController.text} إلى تاريخ: ${_endDateController.text}',
              textDirection: pw.TextDirection.rtl,
              style: const pw.TextStyle(fontSize: 10),
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
              headerDecoration: const pw.BoxDecoration(
                color: PdfColors.blueGrey800,
              ),
              cellStyle: const pw.TextStyle(fontSize: 8),
              cellAlignments: {
                0: pw.Alignment.center,
                1: pw.Alignment.center,
                2: pw.Alignment.centerRight,
                3: pw.Alignment.center,
                4: pw.Alignment.center,
                5: pw.Alignment.center,
              },
            ),
          ],
        ),
      );

      final bytes = await pdf.save();
      if (saveAsPdf) {
        final saved = await PrintUtils.savePdf(
          bytes,
          'كشف_حساب_${accountName}',
        );
        if (mounted && saved)
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(PrintUtils.savedPdfMessage)));
      } else {
        await PrintUtils.printPdf(bytes, 'كشف_حساب_${accountName}');
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
                          child: DataTable(
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
