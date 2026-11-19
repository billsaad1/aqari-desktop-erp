import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/permission_policy.dart';
import '../../core/pdf_preview_dialog.dart';
import '../../core/print_utils.dart';
import '../../core/tenant_collection_report_pdf.dart';
import '../../database/database_helper.dart';
import '../../models/tenant_collection_report_model.dart';
import '../../providers/reports_provider.dart';

class TenantCollectionReportScreen extends StatefulWidget {
  const TenantCollectionReportScreen({super.key});

  @override
  State<TenantCollectionReportScreen> createState() =>
      _TenantCollectionReportScreenState();
}

class _TenantCollectionReportScreenState
    extends State<TenantCollectionReportScreen> {
  final _startDateController = TextEditingController(
    text: DateFormat(
      'yyyy-MM-dd',
    ).format(DateTime.now().subtract(const Duration(days: 30))),
  );
  final _endDateController = TextEditingController(
    text: DateFormat('yyyy-MM-dd').format(DateTime.now()),
  );

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
      ).clearTenantCollectionReport();
    }
    setState(() {});
  }

  @override
  void dispose() {
    PermissionRuntime.authorizationRevision.removeListener(
      _onAuthorizationChanged,
    );
    _startDateController.dispose();
    _endDateController.dispose();
    super.dispose();
  }

  Future<void> _selectDate(TextEditingController controller) async {
    final initialDate = DateTime.tryParse(controller.text) ?? DateTime.now();
    final selected = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (selected != null && mounted) {
      setState(() {
        controller.text = DateFormat('yyyy-MM-dd').format(selected);
      });
      Provider.of<ReportsProvider>(
        context,
        listen: false,
      ).clearTenantCollectionReport();
    }
  }

  Future<void> _loadReport() async {
    final start = DateTime.tryParse(_startDateController.text);
    final end = DateTime.tryParse(_endDateController.text);
    if (start == null || end == null || start.isAfter(end)) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('تحقق من صحة فترة التقرير')));
      return;
    }
    await Provider.of<ReportsProvider>(
      context,
      listen: false,
    ).loadTenantCollectionReport(
      _startDateController.text,
      _endDateController.text,
    );
  }

  Future<void> _preview(TenantCollectionReport report) async {
    if (!PermissionRuntime.allows('reports', AppPermissionAction.view)) return;
    try {
      final authorizationUserId = PermissionRuntime.userId;
      final authorizationRole = PermissionRuntime.role;
      final reports = Provider.of<ReportsProvider>(context, listen: false);
      bool canContinue() =>
          mounted &&
          _startDateController.text == report.startDate &&
          _endDateController.text == report.endDate &&
          identical(reports.tenantCollectionReport, report) &&
          PermissionRuntime.userId == authorizationUserId &&
          PermissionRuntime.role == authorizationRole &&
          PermissionRuntime.allows('reports', AppPermissionAction.view);

      if (!canContinue()) return;
      final companyInfo = await DatabaseHelper.instance.getCompanyInfo();
      if (!canContinue()) return;
      final bytes = await TenantCollectionReportPdf.build(
        report: report,
        companyInfo: companyInfo,
        currency: PrintUtils.currencyInArabic(report.currency),
      );
      if (!canContinue()) return;
      if (!mounted) return;
      await PdfDocumentPreviewDialog.show(
        context: context,
        bytes: bytes,
        fileName: 'تحصيل_المستأجرين_${report.startDate}_${report.endDate}',
        preferredIntent: PdfPreviewIntent.printDocument,
        permissionModule: 'reports',
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تعذر تجهيز تقرير تحصيل المستأجرين: $error')),
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
        final report = reports.tenantCollectionReport;
        final isCurrentReport =
            report != null &&
            report.startDate == _startDateController.text &&
            report.endDate == _endDateController.text;

        return Padding(
          padding: const EdgeInsets.all(20),
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
                        'تحصيل المستأجرين',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'يعرض سندات القبض المرحلة مرة واحدة، ويقارن سجل التخصيص التفصيلي بالسجلات التاريخية للقسط والفاتورة. لا يخصم الاسترداد إلا إذا طابق السند والمصدر وبقي ضمن سقف التخصيص الأصلي.',
                      ),
                      const SizedBox(height: 16),
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          _dateField('من تاريخ', _startDateController),
                          _dateField('إلى تاريخ', _endDateController),
                          FilledButton.icon(
                            onPressed: reports.isTenantCollectionReportLoading
                                ? null
                                : _loadReport,
                            icon: reports.isTenantCollectionReportLoading
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.payments_outlined),
                            label: const Text('عرض التقرير'),
                          ),
                          OutlinedButton.icon(
                            onPressed: isCurrentReport
                                ? () => _preview(report)
                                : null,
                            icon: const Icon(Icons.picture_as_pdf_outlined),
                            label: const Text('معاينة التقرير'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              if (reports.tenantCollectionErrorMessage != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: _errorBox(reports.tenantCollectionErrorMessage!),
                ),
              const SizedBox(height: 12),
              if (isCurrentReport) ...[
                _summary(report),
                const SizedBox(height: 10),
                Expanded(
                  child: report.rows.isEmpty
                      ? const Center(
                          child: Text(
                            'لا توجد سندات قبض أو استردادات مرتبطة في الفترة المحددة.',
                          ),
                        )
                      : _table(report),
                ),
              ] else if (reports.isTenantCollectionReportLoading) ...[
                const Expanded(
                  child: Center(child: CircularProgressIndicator()),
                ),
              ] else if (reports.tenantCollectionErrorMessage != null) ...[
                const Expanded(
                  child: Center(
                    child: Text('تعذر إعداد التقرير؛ راجع الرسالة أعلاه.'),
                  ),
                ),
              ] else ...[
                const Expanded(
                  child: Center(
                    child: Text('حدد الفترة ثم اختر «عرض التقرير».'),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _dateField(String label, TextEditingController controller) => SizedBox(
    width: 220,
    child: TextFormField(
      controller: controller,
      readOnly: true,
      onTap: () => _selectDate(controller),
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: const Icon(Icons.calendar_month_outlined),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
        isDense: true,
      ),
    ),
  );

  Widget _summary(TenantCollectionReport report) => Card(
    elevation: 0.5,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Wrap(
        spacing: 24,
        runSpacing: 12,
        children: [
          _metric(
            'إجمالي القبوضات المرحلة',
            report.grossReceiptsMinor,
            report.currency,
          ),
          _metric(
            'الاستردادات المرتبطة المطابقة',
            report.linkedRefundsMinor,
            report.currency,
          ),
          _metric(
            'صافي التحصيل المؤكد',
            report.netCollectedMinor,
            report.currency,
            color: Colors.green.shade700,
          ),
          _metric(
            'قبوض بلا تخصيص مثبت',
            report.unallocatedReceiptsMinor,
            report.currency,
          ),
          _metric(
            'استردادات تحتاج مراجعة',
            report.unverifiedRefundsMinor,
            report.currency,
          ),
          _countMetric(
            'سندات تخصيصها يحتاج مراجعة',
            report.sourceMismatchVoucherCount,
          ),
        ],
      ),
    ),
  );

  Widget _metric(String label, int amount, String currency, {Color? color}) =>
      SizedBox(
        width: 205,
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

  Widget _countMetric(String label, int count) => SizedBox(
    width: 205,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 2),
        Text('$count', style: const TextStyle(fontWeight: FontWeight.bold)),
      ],
    ),
  );

  Widget _table(TenantCollectionReport report) => Card(
    clipBehavior: Clip.antiAlias,
    elevation: 1,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    child: Scrollbar(
      thumbVisibility: true,
      child: SingleChildScrollView(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            headingRowColor: WidgetStatePropertyAll(
              Theme.of(context).colorScheme.surfaceContainerHighest,
            ),
            columns: const [
              DataColumn(label: Text('رقم السند')),
              DataColumn(label: Text('التاريخ')),
              DataColumn(label: Text('المستأجر')),
              DataColumn(label: Text('النوع')),
              DataColumn(label: Text('المبلغ الموقّع'), numeric: true),
              DataColumn(label: Text('سند القبض المصدر')),
              DataColumn(label: Text('حالة التخصيص')),
              DataColumn(label: Text('اتساق مرجع التخصيص')),
            ],
            rows: [
              for (final row in report.rows)
                DataRow(
                  cells: [
                    DataCell(Text(row.voucherId.toString())),
                    DataCell(Text(row.voucherDate)),
                    DataCell(Text(row.tenantName)),
                    DataCell(
                      Text(
                        row.isRefund
                            ? row.isVerifiedRefund
                                  ? 'استرداد مرتبط'
                                  : 'استرداد للمراجعة'
                            : 'قبض',
                        style: TextStyle(
                          color: row.isRefund
                              ? row.isVerifiedRefund
                                    ? Colors.orange.shade800
                                    : Colors.red.shade700
                              : Colors.green.shade700,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    DataCell(
                      Text(
                        _amount(row.amountMinor),
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: row.amountMinor < 0
                              ? Colors.red.shade700
                              : null,
                        ),
                      ),
                    ),
                    DataCell(
                      Text(
                        row.sourceReceiptVoucherIds.isEmpty
                            ? '—'
                            : row.sourceReceiptVoucherIds,
                      ),
                    ),
                    DataCell(
                      Text(
                        row.allocationStatus,
                        style: TextStyle(
                          color:
                              row.allocationStatus == 'التخصيص مطابق' ||
                                  row.allocationStatus == 'مرتبط ومطابق'
                              ? Colors.green.shade700
                              : Colors.orange.shade800,
                        ),
                      ),
                    ),
                    DataCell(
                      Text(
                        row.sourceConsistencyStatus,
                        style: TextStyle(
                          color: row.sourceMismatchCount > 0
                              ? Colors.red.shade700
                              : row.sourceConsistencyStatus ==
                                    'لا توجد تخصيصات للمقارنة'
                              ? Colors.grey.shade700
                              : Colors.green.shade700,
                        ),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
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
