import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat, NumberFormat;
import 'package:provider/provider.dart';

import '../../core/permission_policy.dart';
import '../../core/pdf_preview_dialog.dart';
import '../../core/print_utils.dart';
import '../../core/tenant_aging_report_pdf.dart';
import '../../database/database_helper.dart';
import '../../models/tenant_aging_report_model.dart';
import '../../providers/reports_provider.dart';

class TenantAgingReportScreen extends StatefulWidget {
  const TenantAgingReportScreen({super.key});

  @override
  State<TenantAgingReportScreen> createState() =>
      _TenantAgingReportScreenState();
}

class _TenantAgingReportScreenState extends State<TenantAgingReportScreen> {
  final _asOfController = TextEditingController(
    text: DateFormat('yyyy-MM-dd').format(DateTime.now()),
  );
  final _agingTableScrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    PermissionRuntime.authorizationRevision.addListener(
      _onAuthorizationChanged,
    );
  }

  void _onAuthorizationChanged() {
    if (!mounted) return;
    if (!PermissionRuntime.allows('reports', AppPermissionAction.view)) {
      Provider.of<ReportsProvider>(
        context,
        listen: false,
      ).clearTenantAgingReport();
    }
    setState(() {});
  }

  @override
  void dispose() {
    PermissionRuntime.authorizationRevision.removeListener(
      _onAuthorizationChanged,
    );
    _asOfController.dispose();
    _agingTableScrollController.dispose();
    super.dispose();
  }

  Future<void> _selectDate() async {
    final initialDate =
        DateTime.tryParse(_asOfController.text) ?? DateTime.now();
    final selected = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (selected != null && mounted) {
      setState(() {
        _asOfController.text = DateFormat('yyyy-MM-dd').format(selected);
      });
      Provider.of<ReportsProvider>(
        context,
        listen: false,
      ).clearTenantAgingReport();
    }
  }

  Future<void> _loadReport() async {
    final asOf = DateTime.tryParse(_asOfController.text);
    if (asOf == null ||
        DateFormat('yyyy-MM-dd').format(asOf) != _asOfController.text) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('أدخل تاريخ قطع صحيحًا بصيغة YYYY-MM-DD')),
      );
      return;
    }
    await Provider.of<ReportsProvider>(
      context,
      listen: false,
    ).loadTenantAgingReport(_asOfController.text);
  }

  Future<void> _preview(TenantAgingReport report) async {
    if (!PermissionRuntime.allows('reports', AppPermissionAction.view)) return;
    try {
      final authorizationUserId = PermissionRuntime.userId;
      final authorizationRole = PermissionRuntime.role;
      final reports = Provider.of<ReportsProvider>(context, listen: false);
      bool canContinue() =>
          mounted &&
          _asOfController.text == report.asOfDate &&
          identical(reports.tenantAgingReport, report) &&
          PermissionRuntime.userId == authorizationUserId &&
          PermissionRuntime.role == authorizationRole &&
          PermissionRuntime.allows('reports', AppPermissionAction.view);

      if (!canContinue()) return;
      final companyInfo = await DatabaseHelper.instance.getCompanyInfo();
      if (!canContinue()) return;
      final bytes = await TenantAgingReportPdf.build(
        report: report,
        companyInfo: companyInfo,
        currency: PrintUtils.currencyInArabic(report.currency),
      );
      if (!canContinue() || !mounted) return;
      await PdfDocumentPreviewDialog.show(
        context: context,
        bytes: bytes,
        fileName: 'أعمار_ديون_المستأجرين_${report.asOfDate}',
        preferredIntent: PdfPreviewIntent.printDocument,
        permissionModule: 'reports',
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تعذر تجهيز تقرير أعمار الديون: $error')),
        );
      }
    }
  }

  String _amount(int minor) =>
      NumberFormat('#,##0.00;-#,##0.00', 'en_US').format(minor / 100);

  @override
  Widget build(BuildContext context) {
    return Consumer<ReportsProvider>(
      builder: (context, reports, child) {
        if (!PermissionRuntime.allows('reports', AppPermissionAction.view)) {
          return const Center(
            child: Text('لا تملك صلاحية عرض التقارير والاستعلامات.'),
          );
        }
        final report = reports.tenantAgingReport;
        final isCurrentReport =
            report != null && report.asOfDate == _asOfController.text;

        return Directionality(
          textDirection: TextDirection.rtl,
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Card(
                  elevation: 1,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'أعمار ديون المستأجرين',
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 5),
                        const Text(
                          'تقرير قراءة فقط للأقساط القائمة حسب تاريخ القطع. يعتمد الخصم على تخصيصات القبض التفصيلية المتسقة والاستردادات المرتبطة بمصدرها؛ المقبوضات غير المخصصة والسجلات التاريخية المختلف عليها تظهر كاستثناءات ولا تخفض الرصيد المؤكد.',
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'تنبيه: القطع حسب تواريخ المستندات المنشورة حاليًا (الاستحقاق/الفاتورة/السند)، وليس لقطة لما كان معروفًا للنظام عند ذلك التاريخ.',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 14),
                        Wrap(
                          spacing: 12,
                          runSpacing: 12,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            SizedBox(
                              width: 230,
                              child: TextFormField(
                                controller: _asOfController,
                                readOnly: true,
                                onTap: _selectDate,
                                decoration: InputDecoration(
                                  labelText: 'تاريخ القطع',
                                  prefixIcon: const Icon(Icons.event_outlined),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  isDense: true,
                                ),
                              ),
                            ),
                            FilledButton.icon(
                              onPressed: reports.isTenantAgingReportLoading
                                  ? null
                                  : _loadReport,
                              icon: reports.isTenantAgingReportLoading
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.assessment_outlined),
                              label: const Text('عرض التقرير'),
                            ),
                            OutlinedButton.icon(
                              onPressed: isCurrentReport
                                  ? () => _preview(report)
                                  : null,
                              icon: const Icon(Icons.picture_as_pdf_outlined),
                              label: const Text('معاينة PDF'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                if (reports.tenantAgingErrorMessage != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: _errorBox(reports.tenantAgingErrorMessage!),
                  ),
                const SizedBox(height: 10),
                if (isCurrentReport) ...[
                  _summary(report),
                  const SizedBox(height: 10),
                  Expanded(
                    child: ListView(
                      children: [
                        if (report.rows.isEmpty)
                          const Padding(
                            padding: EdgeInsets.all(20),
                            child: Center(
                              child: Text(
                                'لا توجد أرصدة أقساط مؤكدة في تاريخ القطع.',
                              ),
                            ),
                          )
                        else
                          _agingTable(report),
                        const SizedBox(height: 12),
                        _exceptionsTable(report),
                        const SizedBox(height: 16),
                      ],
                    ),
                  ),
                ] else if (reports.isTenantAgingReportLoading) ...[
                  const Expanded(
                    child: Center(child: CircularProgressIndicator()),
                  ),
                ] else if (reports.tenantAgingErrorMessage != null) ...[
                  const Expanded(
                    child: Center(
                      child: Text('تعذر إعداد التقرير؛ راجع الرسالة أعلاه.'),
                    ),
                  ),
                ] else ...[
                  const Expanded(
                    child: Center(
                      child: Text('حدد تاريخ القطع ثم اختر «عرض التقرير»'),
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _summary(TenantAgingReport report) => Card(
    elevation: 0.5,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    child: Padding(
      padding: const EdgeInsets.all(13),
      child: Wrap(
        spacing: 20,
        runSpacing: 12,
        children: [
          _metric('غير مستحق', report.notDueMinor, report.currency),
          _metric('0–30 يومًا', report.days0To30Minor, report.currency),
          _metric('31–60 يومًا', report.days31To60Minor, report.currency),
          _metric('61–90 يومًا', report.days61To90Minor, report.currency),
          _metric('91+ يومًا', report.days91PlusMinor, report.currency),
          _metric(
            'إجمالي الرصيد المؤكد',
            report.totalOutstandingMinor,
            report.currency,
            color: Colors.blueGrey.shade800,
          ),
          SizedBox(
            width: 205,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('مستندات/مبالغ للمراجعة'),
                const SizedBox(height: 2),
                Text(
                  '${report.exceptions.length} مستندات • ${_amount(report.exceptionAmountMinor)} ${PrintUtils.currencyInArabic(report.currency)}',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Colors.orange.shade900,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );

  Widget _metric(String label, int amount, String currency, {Color? color}) =>
      SizedBox(
        width: 165,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 2),
            Text(
              '${_amount(amount)} ${PrintUtils.currencyInArabic(currency)}',
              style: TextStyle(fontWeight: FontWeight.bold, color: color),
            ),
          ],
        ),
      );

  Widget _agingTable(TenantAgingReport report) => Card(
    clipBehavior: Clip.antiAlias,
    elevation: 1,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    child: Scrollbar(
      thumbVisibility: true,
      controller: _agingTableScrollController,
      child: SingleChildScrollView(
        controller: _agingTableScrollController,
        scrollDirection: Axis.horizontal,
        child: DataTable(
          headingRowColor: WidgetStatePropertyAll(
            Theme.of(context).colorScheme.surfaceContainerHighest,
          ),
          columns: const [
            DataColumn(label: Text('المستأجر')),
            DataColumn(label: Text('العقار')),
            DataColumn(label: Text('الوحدة')),
            DataColumn(label: Text('رقم القسط')),
            DataColumn(label: Text('الاستحقاق')),
            DataColumn(label: Text('أيام التأخير'), numeric: true),
            DataColumn(label: Text('الشريحة')),
            DataColumn(label: Text('الالتزام'), numeric: true),
            DataColumn(label: Text('المسدد المؤكد'), numeric: true),
            DataColumn(label: Text('الرصيد'), numeric: true),
          ],
          rows: [
            for (final row in report.rows)
              DataRow(
                cells: [
                  DataCell(Text(row.tenantName)),
                  DataCell(Text(row.propertyName)),
                  DataCell(Text(row.unitNumber)),
                  DataCell(Text(row.installmentId.toString())),
                  DataCell(Text(row.dueDate)),
                  DataCell(Text(row.daysOverdue.toString())),
                  DataCell(Text(row.bucket.label)),
                  DataCell(Text(_amount(row.obligationMinor))),
                  DataCell(Text(_amount(row.paidMinor))),
                  DataCell(
                    Text(
                      _amount(row.balanceMinor),
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    ),
  );

  Widget _exceptionsTable(TenantAgingReport report) => Card(
    clipBehavior: Clip.antiAlias,
    elevation: 1,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'استثناءات للمراجعة — لا تُخصم من الرصيد المؤكد',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          if (report.exceptions.isEmpty)
            const Text('لا توجد استثناءات مسجلة.')
          else
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                headingRowColor: WidgetStatePropertyAll(
                  Theme.of(context).colorScheme.surfaceContainerHighest,
                ),
                columns: const [
                  DataColumn(label: Text('المستند')),
                  DataColumn(label: Text('الرقم')),
                  DataColumn(label: Text('التاريخ')),
                  DataColumn(label: Text('المستأجر')),
                  DataColumn(label: Text('المبلغ المعزول'), numeric: true),
                  DataColumn(label: Text('سبب المراجعة')),
                ],
                rows: [
                  for (final exception in report.exceptions)
                    DataRow(
                      cells: [
                        DataCell(Text(exception.documentType)),
                        DataCell(Text(exception.documentId.toString())),
                        DataCell(Text(exception.documentDate)),
                        DataCell(Text(exception.tenantName)),
                        DataCell(Text(_amount(exception.amountMinor))),
                        DataCell(
                          SizedBox(
                            width: 360,
                            child: Text(exception.reason, softWrap: true),
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
        ],
      ),
    ),
  );

  Widget _errorBox(String message) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.errorContainer,
      borderRadius: BorderRadius.circular(10),
    ),
    child: Text(
      message,
      style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer),
    ),
  );
}
