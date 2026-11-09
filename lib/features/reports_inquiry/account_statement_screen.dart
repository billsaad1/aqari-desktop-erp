import 'package:flutter/material.dart';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import '../../providers/reports_provider.dart';
import '../../providers/accounting_provider.dart';
import '../../database/database_helper.dart';

class AccountStatementScreen extends StatefulWidget {
  const AccountStatementScreen({super.key});

  @override
  State<AccountStatementScreen> createState() => _AccountStatementScreenState();
}

class _AccountStatementScreenState extends State<AccountStatementScreen> {
  final _startDateController = TextEditingController(text: DateFormat('yyyy-MM-dd').format(DateTime.now().subtract(const Duration(days: 30))));
  final _endDateController = TextEditingController(text: DateFormat('yyyy-MM-dd').format(DateTime.now()));
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
      Provider.of<ReportsProvider>(context, listen: false).loadAccountStatement(
        _selectedAccountId!,
        _startDateController.text,
        _endDateController.text
      );
    }
  }

  Future<void> _printStatement(List<Map<String, dynamic>> statement, String accountName) async {
    final companyInfo = await DatabaseHelper.instance.getCompanyInfo();
    final String companyName = companyInfo?['name_ar'] ?? 'مؤسسة عبدالله النقيب التجارية';
    final String companyAddress = companyInfo?['address'] ?? '';
    final String companyTax = companyInfo?['tax_number'] ?? '';
    final String? logoPath = companyInfo?['logo_path'];

    final fontData = await rootBundle.load("assets/fonts/Cairo-Regular.ttf").catchError((_) => ByteData.view(Uint8List(0).buffer));
    final ttf = fontData.lengthInBytes > 0 ? pw.Font.ttf(fontData) : pw.Font.helvetica();
    final fontBoldData = await rootBundle.load("assets/fonts/Cairo-Bold.ttf").catchError((_) => ByteData.view(Uint8List(0).buffer));
    final ttfBold = fontBoldData.lengthInBytes > 0 ? pw.Font.ttf(fontBoldData) : pw.Font.helveticaBold();

    final pdf = pw.Document();

    double runningBalance = 0.0;
    final tableData = statement.map((s) {
      double d = (s['debit'] as num).toDouble();
      double c = (s['credit'] as num).toDouble();
      runningBalance += (d - c); // Simplistic balance logic for print (assuming asset/expense, needs strict logic based on type in prod)

      return [
        s['date'],
        s['voucher_no'].toString(),
        s['description'],
        d.toStringAsFixed(2),
        c.toStringAsFixed(2),
        runningBalance.toStringAsFixed(2),
      ];
    }).toList();

    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        textDirection: pw.TextDirection.rtl,
        theme: pw.ThemeData.withFont(base: ttf, bold: ttfBold),
        build: (pw.Context context) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text(companyName, style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold)),
                      pw.Text('العنوان: $companyAddress', style: const pw.TextStyle(fontSize: 12)),
                      if (companyTax.isNotEmpty) pw.Text('الرقم الضريبي: $companyTax', style: const pw.TextStyle(fontSize: 12)),
                    ],
                  ),
                  if (logoPath != null && logoPath.isNotEmpty && File(logoPath).existsSync())
                    pw.Image(
                      pw.MemoryImage(File(logoPath).readAsBytesSync()),
                      width: 60,
                      height: 60,
                    )
                ],
              ),
              pw.Divider(thickness: 2),
              pw.SizedBox(height: 10),
              pw.Center(
                child: pw.Text('كشف حساب تفصيلي', style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold, decoration: pw.TextDecoration.underline)),
              ),
              pw.SizedBox(height: 30),
              pw.Text('الحساب: $accountName', style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
              pw.Text('من تاريخ: ${_startDateController.text} إلى تاريخ: ${_endDateController.text}', style: const pw.TextStyle(fontSize: 14)),
              pw.SizedBox(height: 20),
              pw.TableHelper.fromTextArray(
                headers: ['التاريخ', 'رقم السند', 'البيان', 'مدين', 'دائن', 'الرصيد'],
                data: tableData,
                headerStyle: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold, color: PdfColors.white),
                headerDecoration: const pw.BoxDecoration(color: PdfColors.blueGrey800),
                cellStyle: const pw.TextStyle(fontSize: 12),
                cellAlignments: {
                  0: pw.Alignment.center,
                  1: pw.Alignment.center,
                  2: pw.Alignment.centerRight,
                  3: pw.Alignment.center,
                  4: pw.Alignment.center,
                  5: pw.Alignment.center,
                }
              ),
            ],
          );
        },
      ),
    );

    await Printing.layoutPdf(onLayout: (PdfPageFormat format) async => pdf.save());
  }

  @override
  Widget build(BuildContext context) {
    return Consumer2<ReportsProvider, AccountingProvider>(
      builder: (context, reportsProv, accProv, child) {
        if (accProv.isLoading) return const Center(child: CircularProgressIndicator());

        double runningBalance = 0.0;
        String accountName = _selectedAccountId != null
            ? accProv.accounts.firstWhere((a) => a['id'] == _selectedAccountId)['name']
            : '';

        return Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('كشف الحساب التفصيلي', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: DropdownButtonFormField<int>(
                      value: _selectedAccountId,
                      items: accProv.accounts.map((a) => DropdownMenuItem<int>(
                        value: a['id'],
                        child: Text('${a['code']} - ${a['name']}'),
                      )).toList(),
                      onChanged: (val) => setState(() => _selectedAccountId = val),
                      decoration: const InputDecoration(labelText: 'اختر الحساب', border: OutlineInputBorder()),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    flex: 1,
                    child: TextFormField(
                      controller: _startDateController,
                      decoration: const InputDecoration(labelText: 'من تاريخ', border: OutlineInputBorder()),
                      readOnly: true,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    flex: 1,
                    child: TextFormField(
                      controller: _endDateController,
                      decoration: const InputDecoration(labelText: 'إلى تاريخ', border: OutlineInputBorder()),
                      readOnly: true,
                    ),
                  ),
                  const SizedBox(width: 16),
                  ElevatedButton(
                    onPressed: _selectedAccountId != null ? _loadStatement : null,
                    style: ElevatedButton.styleFrom(padding: const EdgeInsets.all(20)),
                    child: const Text('عرض الكشف'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    onPressed: reportsProv.accountStatement.isNotEmpty
                        ? () => _printStatement(reportsProv.accountStatement, accountName)
                        : null,
                    icon: const Icon(Icons.print),
                    label: const Text('طباعة'),
                    style: ElevatedButton.styleFrom(padding: const EdgeInsets.all(20), backgroundColor: Colors.orange),
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
                      rows: reportsProv.accountStatement.map((s) {
                        double d = (s['debit'] as num).toDouble();
                        double c = (s['credit'] as num).toDouble();
                        // For a real accounting system, the cumulative logic should respect account type
                        runningBalance += (d - c);

                        return DataRow(cells: [
                          DataCell(Text(s['date'])),
                          DataCell(Text(s['voucher_no'].toString())),
                          DataCell(Text(s['description'] ?? '')),
                          DataCell(Text(d.toStringAsFixed(2))),
                          DataCell(Text(c.toStringAsFixed(2))),
                          DataCell(Text(runningBalance.toStringAsFixed(2))),
                        ]);
                      }).toList(),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
