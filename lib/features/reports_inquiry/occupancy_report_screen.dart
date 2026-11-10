import "../../core/print_utils.dart";
import 'package:flutter/material.dart';
import '../../core/erp_data_table.dart';
import 'package:provider/provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
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

  Future<void> _printReport(
    List<Map<String, dynamic>> stats, {
    required bool saveAsPdf,
  }) async {
    try {
      final companyInfo = await DatabaseHelper.instance.getCompanyInfo();
      final pdf = pw.Document();
      final theme = await PrintUtils.loadArabicTheme();

      final tableData = stats.map((s) {
        final total = (s['total_units'] as num?)?.toDouble() ?? 0;
        final rented = (s['rented_units'] as num?)?.toDouble() ?? 0;
        final vacant = (s['vacant_units'] as num?)?.toDouble() ?? 0;
        final pct = total > 0 ? (rented / total) * 100 : 0.0;
        return [
          s['property_name']?.toString() ?? '',
          total.toInt().toString(),
          rented.toInt().toString(),
          vacant.toInt().toString(),
          '${pct.toStringAsFixed(1)} %',
        ];
      }).toList();

      pdf.addPage(
        pw.MultiPage(
          pageTheme: pw.PageTheme(
            pageFormat: PdfPageFormat.a4,
            textDirection: pw.TextDirection.rtl,
            theme: theme,
            buildBackground: (pw.Context context) =>
                PrintUtils.buildWatermark(companyInfo),
          ),
          header: (_) => PrintUtils.buildHeader(companyInfo, false),
          footer: (context) => PrintUtils.buildPageFooter(context, companyInfo),
          build: (_) => [
            pw.Center(
              child: pw.Text(
                'تقرير حالة الوحدات (الإشغال والشواغر)',
                textDirection: pw.TextDirection.rtl,
                style: pw.TextStyle(
                  fontSize: 18,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
            ),
            pw.SizedBox(height: 18),
            pw.TableHelper.fromTextArray(
              headers: [
                'اسم العقار',
                'إجمالي الوحدات',
                'المؤجر',
                'الشاغر',
                'نسبة الإشغال',
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
              cellStyle: const pw.TextStyle(fontSize: 9),
              cellAlignments: {
                0: pw.Alignment.centerRight,
                1: pw.Alignment.center,
                2: pw.Alignment.center,
                3: pw.Alignment.center,
                4: pw.Alignment.center,
              },
            ),
          ],
        ),
      );
      final bytes = await pdf.save();
      if (saveAsPdf) {
        final saved = await PrintUtils.savePdf(bytes, 'تقرير_الإشغال');
        if (mounted && saved)
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(PrintUtils.savedPdfMessage)));
      } else {
        await PrintUtils.printPdf(bytes, 'تقرير_الإشغال');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تعذر تجهيز/طباعة تقرير الإشغال: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ReportsProvider>(
      builder: (context, provider, child) {
        if (provider.isLoading)
          return const Center(child: CircularProgressIndicator());

        return Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'تقرير حالة الوحدات',
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                  ),
                  ElevatedButton.icon(
                    onPressed: provider.occupancyStats.isNotEmpty
                        ? () => _printReport(
                            provider.occupancyStats,
                            saveAsPdf: false,
                          )
                        : null,
                    icon: const Icon(Icons.print),
                    label: const Text('طباعة'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: provider.occupancyStats.isNotEmpty
                        ? () => _printReport(
                            provider.occupancyStats,
                            saveAsPdf: true,
                          )
                        : null,
                    icon: const Icon(Icons.picture_as_pdf),
                    label: const Text('حفظ PDF'),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              Expanded(
                child: SingleChildScrollView(
                  child: ErpDataTable(
                    columns: const [
                      DataColumn(label: Text('اسم العقار')),
                      DataColumn(label: Text('إجمالي الوحدات')),
                      DataColumn(label: Text('المؤجر')),
                      DataColumn(label: Text('الشاغر')),
                      DataColumn(label: Text('نسبة الإشغال')),
                    ],
                    rows: provider.occupancyStats.map((stat) {
                      double pct = stat['total_units'] > 0
                          ? (stat['rented_units'] / stat['total_units']) * 100
                          : 0.0;
                      return DataRow(
                        cells: [
                          DataCell(Text(stat['property_name'] ?? '')),
                          DataCell(Text(stat['total_units'].toString())),
                          DataCell(Text(stat['rented_units'].toString())),
                          DataCell(Text(stat['vacant_units'].toString())),
                          DataCell(Text('${pct.toStringAsFixed(1)} %')),
                        ],
                      );
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
