import "../../core/print_utils.dart";
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import '../../providers/reports_provider.dart';
import '../../database/database_helper.dart';

class OccupancyReportScreen extends StatefulWidget {
  const OccupancyReportScreen({super.key});

  @override
  State<OccupancyReportScreen> createState() => _OccupancyReportScreenState();
}

class _OccupancyReportScreenState extends State<OccupancyReportScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Provider.of<ReportsProvider>(context, listen: false).loadOccupancyStats();
    });
  }

  Future<void> _printReport(List<Map<String, dynamic>> stats) async {
    final companyInfo = await DatabaseHelper.instance.getCompanyInfo();

    final fontData = await rootBundle.load("assets/fonts/Cairo-Regular.ttf").catchError((_) => ByteData.view(Uint8List(0).buffer));
    final ttf = fontData.lengthInBytes > 0 ? pw.Font.ttf(fontData) : pw.Font.helvetica();
    final fontBoldData = await rootBundle.load("assets/fonts/Cairo-Bold.ttf").catchError((_) => ByteData.view(Uint8List(0).buffer));
    final ttfBold = fontBoldData.lengthInBytes > 0 ? pw.Font.ttf(fontBoldData) : pw.Font.helveticaBold();

    final pdf = pw.Document();

    final tableData = stats.map((s) {
      double pct = s['total_units'] > 0 ? (s['rented_units'] / s['total_units']) * 100 : 0.0;
      return [
        s['property_name'],
        s['total_units'].toString(),
        s['rented_units'].toString(),
        s['vacant_units'].toString(),
        '${pct.toStringAsFixed(1)} %'
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
              PrintUtils.buildHeader(companyInfo, false), // Administrative report, no financial docs
              pw.SizedBox(height: 10),
              pw.Center(
                child: pw.Text('تقرير حالة الوحدات (الإشغال والشواغر)', style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold, decoration: pw.TextDecoration.underline)),
              ),
              pw.SizedBox(height: 30),
              pw.TableHelper.fromTextArray(
                headers: ['اسم العقار', 'إجمالي الوحدات', 'المؤجر', 'الشاغر', 'نسبة الإشغال'],
                data: tableData,
                headerStyle: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold, color: PdfColors.white),
                headerDecoration: const pw.BoxDecoration(color: PdfColors.blueGrey800),
                cellStyle: const pw.TextStyle(fontSize: 12),
                cellAlignments: {
                  0: pw.Alignment.centerRight,
                  1: pw.Alignment.center,
                  2: pw.Alignment.center,
                  3: pw.Alignment.center,
                  4: pw.Alignment.center,
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
    return Consumer<ReportsProvider>(
      builder: (context, provider, child) {
        if (provider.isLoading) return const Center(child: CircularProgressIndicator());

        return Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('تقرير حالة الوحدات', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
                  ElevatedButton.icon(
                    onPressed: provider.occupancyStats.isNotEmpty ? () => _printReport(provider.occupancyStats) : null,
                    icon: const Icon(Icons.print),
                    label: const Text('طباعة وتصدير PDF'),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              Expanded(
                child: SingleChildScrollView(
                  child: DataTable(
                    columns: const [
                      DataColumn(label: Text('اسم العقار')),
                      DataColumn(label: Text('إجمالي الوحدات')),
                      DataColumn(label: Text('المؤجر')),
                      DataColumn(label: Text('الشاغر')),
                      DataColumn(label: Text('نسبة الإشغال')),
                    ],
                    rows: provider.occupancyStats.map((stat) {
                      double pct = stat['total_units'] > 0 ? (stat['rented_units'] / stat['total_units']) * 100 : 0.0;
                      return DataRow(cells: [
                        DataCell(Text(stat['property_name'] ?? '')),
                        DataCell(Text(stat['total_units'].toString())),
                        DataCell(Text(stat['rented_units'].toString())),
                        DataCell(Text(stat['vacant_units'].toString())),
                        DataCell(Text('${pct.toStringAsFixed(1)} %')),
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
