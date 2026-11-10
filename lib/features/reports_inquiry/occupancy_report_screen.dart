import "../../core/print_utils.dart";
import '../../core/pdf_preview_dialog.dart';
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
      final totalUnits = stats.fold<double>(
        0,
        (sum, item) => sum + ((item['total_units'] as num?)?.toDouble() ?? 0),
      );
      final rentedUnits = stats.fold<double>(
        0,
        (sum, item) => sum + ((item['rented_units'] as num?)?.toDouble() ?? 0),
      );
      final vacantUnits = stats.fold<double>(
        0,
        (sum, item) => sum + ((item['vacant_units'] as num?)?.toDouble() ?? 0),
      );
      final occupancy = totalUnits == 0 ? 0.0 : rentedUnits / totalUnits * 100;

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
          pct.toStringAsFixed(1),
        ];
      }).toList();

      pdf.addPage(
        pw.MultiPage(
          pageTheme: PrintUtils.pageTheme(
            theme: theme,
            companyInfo: companyInfo,
            margin: const pw.EdgeInsets.fromLTRB(32, 30, 32, 34),
          ),
          header: (_) => PrintUtils.buildHeader(companyInfo, false),
          footer: (context) => PrintUtils.buildPageFooter(context, companyInfo),
          build: (_) => [
            pw.Center(
              child: pw.Text(
                'تقرير حالة الوحدات (الإشغال والشواغر)',
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
            pw.Row(
              children: [
                _pdfSummaryMetric(
                  'إجمالي الوحدات',
                  totalUnits.toInt().toString(),
                ),
                _pdfSummaryMetric('المؤجر', rentedUnits.toInt().toString()),
                _pdfSummaryMetric('الشاغر', vacantUnits.toInt().toString()),
                _pdfSummaryMetric(
                  'نسبة الإشغال',
                  '${occupancy.toStringAsFixed(1)}%',
                ),
              ],
            ),
            pw.SizedBox(height: 8),
            PrintUtils.buildLabelValue(
              'تاريخ إعداد التقرير',
              DateTime.now().toIso8601String().substring(0, 10),
              valueDirection: pw.TextDirection.ltr,
              labelWidth: 95,
              fontSize: 8,
            ),
            pw.SizedBox(height: 8),
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
              headerDecoration: pw.BoxDecoration(color: PrintUtils.brandNavy),
              cellStyle: const pw.TextStyle(fontSize: 9, lineSpacing: 2),
              cellPadding: const pw.EdgeInsets.symmetric(
                horizontal: 5,
                vertical: 7,
              ),
              tableDirection: pw.TextDirection.rtl,
              headerDirection: pw.TextDirection.rtl,
              columnWidths: const {
                0: pw.FlexColumnWidth(2.8),
                1: pw.FlexColumnWidth(1.1),
                2: pw.FlexColumnWidth(1),
                3: pw.FlexColumnWidth(1),
                4: pw.FlexColumnWidth(1.4),
              },
              border: pw.TableBorder.all(
                color: PrintUtils.softBorder,
                width: 0.5,
              ),
              oddRowDecoration: pw.BoxDecoration(color: PrintUtils.softSurface),
              cellAlignments: {
                0: pw.Alignment.centerRight,
                1: pw.Alignment.center,
                2: pw.Alignment.center,
                3: pw.Alignment.center,
                4: pw.Alignment.center,
              },
            ),
            if (stats.isEmpty)
              pw.Padding(
                padding: const pw.EdgeInsets.all(12),
                child: pw.Text(
                  'لا توجد عقارات أو وحدات مسجلة حتى الآن.',
                  textDirection: pw.TextDirection.rtl,
                  textAlign: pw.TextAlign.center,
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
          fileName: 'تقرير_الإشغال',
          preferredIntent: saveAsPdf
              ? PdfPreviewIntent.save
              : PdfPreviewIntent.printDocument,
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تعذر تجهيز/طباعة تقرير الإشغال: $e')),
        );
      }
    }
  }

  pw.Widget _pdfSummaryMetric(String label, String value) => pw.Expanded(
    child: pw.Container(
      margin: const pw.EdgeInsets.symmetric(horizontal: 3),
      padding: const pw.EdgeInsets.symmetric(vertical: 9, horizontal: 5),
      decoration: pw.BoxDecoration(
        color: PrintUtils.softSurface,
        border: pw.Border.all(color: PrintUtils.softBorder),
        borderRadius: pw.BorderRadius.circular(5),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          pw.Text(
            label,
            textDirection: pw.TextDirection.rtl,
            textAlign: pw.TextAlign.center,
            style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700),
          ),
          pw.SizedBox(height: 3),
          pw.Text(
            value,
            textDirection: pw.TextDirection.ltr,
            textAlign: pw.TextAlign.center,
            style: pw.TextStyle(
              fontSize: 13,
              fontWeight: pw.FontWeight.bold,
              color: PrintUtils.brandEmerald,
            ),
          ),
        ],
      ),
    ),
  );

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
