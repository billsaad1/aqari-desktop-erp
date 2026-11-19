import 'dart:ui' as ui;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/invoice_ledger_reconciliation_pdf.dart';
import '../../core/permission_policy.dart';
import '../../core/pdf_preview_dialog.dart';
import '../../core/print_utils.dart';
import '../../database/database_helper.dart';
import '../../models/invoice_ledger_reconciliation_report_model.dart';
import '../../providers/reports_provider.dart';

class InvoiceLedgerReconciliationScreen extends StatefulWidget {
  const InvoiceLedgerReconciliationScreen({
    super.key,
    this.companyInfoLoader,
    this.pdfBuilder,
  });

  final Future<Map<String, dynamic>?> Function()? companyInfoLoader;
  final Future<Uint8List> Function(
    InvoiceLedgerReconciliationReport report,
    List<InvoiceLedgerReconciliationRow> rows,
    String filterLabel,
    Map<String, dynamic>? companyInfo,
    String currency,
  )?
  pdfBuilder;

  @override
  State<InvoiceLedgerReconciliationScreen> createState() =>
      _InvoiceLedgerReconciliationScreenState();
}

class _InvoiceLedgerReconciliationScreenState
    extends State<InvoiceLedgerReconciliationScreen> {
  final _startDateController = TextEditingController(
    text: DateFormat(
      'yyyy-MM-dd',
    ).format(DateTime.now().subtract(const Duration(days: 30))),
  );
  final _endDateController = TextEditingController(
    text: DateFormat('yyyy-MM-dd').format(DateTime.now()),
  );
  String _statusFilter = 'all';

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
      _statusFilter = 'all';
      Provider.of<ReportsProvider>(
        context,
        listen: false,
      ).clearInvoiceLedgerReconciliationReport();
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
    if (selected == null || !mounted) return;
    setState(() {
      controller.text = DateFormat('yyyy-MM-dd').format(selected);
      _statusFilter = 'all';
    });
    Provider.of<ReportsProvider>(
      context,
      listen: false,
    ).clearInvoiceLedgerReconciliationReport();
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
    ).loadInvoiceLedgerReconciliationReport(
      _startDateController.text,
      _endDateController.text,
    );
  }

  List<InvoiceLedgerReconciliationRow> _visibleRows(
    InvoiceLedgerReconciliationReport? report,
  ) {
    if (report == null ||
        report.startDate != _startDateController.text ||
        report.endDate != _endDateController.text) {
      return const [];
    }
    return report.rows
        .where((row) {
          return switch (_statusFilter) {
            'matched' => row.isReconciled,
            'review' => !row.isReconciled,
            _ => true,
          };
        })
        .toList(growable: false);
  }

  String get _filterLabel => switch (_statusFilter) {
    'matched' => 'مطابق فقط',
    'review' => 'يحتاج مراجعة فقط',
    _ => 'كل الفواتير',
  };

  Future<void> _preview(
    InvoiceLedgerReconciliationReport report,
    List<InvoiceLedgerReconciliationRow> rows,
  ) async {
    if (!PermissionRuntime.allows('reports', AppPermissionAction.view)) return;
    final reportsProvider = Provider.of<ReportsProvider>(
      context,
      listen: false,
    );
    final sourceReport = reportsProvider.invoiceLedgerReconciliationReport;
    if (!identical(sourceReport, report)) return;
    final sourceGeneration =
        reportsProvider.invoiceLedgerReconciliationGeneration;
    final selectedFilter = _statusFilter;
    bool isCurrentSource() =>
        reportsProvider.invoiceLedgerReconciliationGeneration ==
            sourceGeneration &&
        identical(reportsProvider.invoiceLedgerReconciliationReport, report);
    bool isCurrentSelection() =>
        _statusFilter == selectedFilter &&
        report.startDate == _startDateController.text &&
        report.endDate == _endDateController.text;

    try {
      final authorizationUserId = PermissionRuntime.userId;
      final authorizationRole = PermissionRuntime.role;
      final companyInfoLoader =
          widget.companyInfoLoader ?? DatabaseHelper.instance.getCompanyInfo;
      final companyInfo = await companyInfoLoader();
      if (!mounted ||
          !isCurrentSource() ||
          !isCurrentSelection() ||
          PermissionRuntime.userId != authorizationUserId ||
          PermissionRuntime.role != authorizationRole ||
          !PermissionRuntime.allows('reports', AppPermissionAction.view)) {
        return;
      }

      final currency = PrintUtils.currencyInArabic(report.currency);
      final pdfBuilder = widget.pdfBuilder;
      final bytes = pdfBuilder == null
          ? await InvoiceLedgerReconciliationPdf.build(
              report: report,
              rows: rows,
              filterLabel: _filterLabel,
              companyInfo: companyInfo,
              currency: currency,
            )
          : await pdfBuilder(report, rows, _filterLabel, companyInfo, currency);
      if (!mounted ||
          !isCurrentSource() ||
          !isCurrentSelection() ||
          PermissionRuntime.userId != authorizationUserId ||
          PermissionRuntime.role != authorizationRole ||
          !PermissionRuntime.allows('reports', AppPermissionAction.view)) {
        return;
      }
      await PdfDocumentPreviewDialog.show(
        context: context,
        bytes: bytes,
        fileName:
            'مطابقة_الفواتير_والقيود_${report.startDate}_${report.endDate}',
        preferredIntent: PdfPreviewIntent.printDocument,
        permissionModule: 'reports',
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تعذر تجهيز تقرير المطابقة: $error')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ReportsProvider>(
      builder: (context, reports, child) {
        if (!PermissionRuntime.allows('reports', AppPermissionAction.view)) {
          return const Center(
            child: Text('لا تملك صلاحية عرض التقارير والاستعلامات.'),
          );
        }
        final report = reports.invoiceLedgerReconciliationReport;
        final reportMatchesPeriod =
            report != null &&
            report.startDate == _startDateController.text &&
            report.endDate == _endDateController.text;
        final List<InvoiceLedgerReconciliationRow> rows = reportMatchesPeriod
            ? _visibleRows(report)
            : const <InvoiceLedgerReconciliationRow>[];
        final filterValue = reportMatchesPeriod ? _statusFilter : 'all';

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
                        'مطابقة الفواتير مع دفتر الأستاذ',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'مراجعة قراءة فقط تقارن صافي الفاتورة بالقسط، وحساب الضريبة المحفوظ بالقيد المرحّل، وذمم المستأجر والإيراد. الفواتير التاريخية بلا مرجع لحساب الضريبة تظهر للمراجعة؛ لا تصحح القيود تلقائيًا.',
                      ),
                      const SizedBox(height: 16),
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          _dateField('من تاريخ الفاتورة', _startDateController),
                          _dateField('إلى تاريخ الفاتورة', _endDateController),
                          SizedBox(
                            width: 230,
                            child: DropdownButtonFormField<String>(
                              key: const ValueKey(
                                'invoiceLedgerReconciliationFilter',
                              ),
                              isExpanded: true,
                              initialValue: filterValue,
                              decoration: const InputDecoration(
                                labelText: 'حالة المطابقة',
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                              items: const [
                                DropdownMenuItem(
                                  value: 'all',
                                  child: Text('كل الفواتير'),
                                ),
                                DropdownMenuItem(
                                  value: 'matched',
                                  child: Text('مطابق فقط'),
                                ),
                                DropdownMenuItem(
                                  value: 'review',
                                  child: Text('يحتاج مراجعة فقط'),
                                ),
                              ],
                              onChanged: !reportMatchesPeriod
                                  ? null
                                  : (value) {
                                      if (value != null) {
                                        setState(() => _statusFilter = value);
                                      }
                                    },
                            ),
                          ),
                          FilledButton.icon(
                            onPressed:
                                reports.isInvoiceLedgerReconciliationLoading
                                ? null
                                : _loadReport,
                            icon: reports.isInvoiceLedgerReconciliationLoading
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.fact_check_outlined),
                            label: const Text('عرض المطابقة'),
                          ),
                          OutlinedButton.icon(
                            onPressed: reportMatchesPeriod
                                ? () => _preview(report, rows)
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
              if (reports.invoiceLedgerReconciliationErrorMessage != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: _errorBox(
                    reports.invoiceLedgerReconciliationErrorMessage!,
                  ),
                ),
              const SizedBox(height: 12),
              if (reportMatchesPeriod) ...[
                _summary(report, rows),
                const SizedBox(height: 10),
                Expanded(
                  child: rows.isEmpty
                      ? const Center(
                          child: Text(
                            'لا توجد فواتير ضمن الفترة والحالة المحددتين.',
                          ),
                        )
                      : _table(rows),
                ),
              ] else if (reports.isInvoiceLedgerReconciliationLoading) ...[
                const Expanded(
                  child: Center(child: CircularProgressIndicator()),
                ),
              ] else if (reports.invoiceLedgerReconciliationErrorMessage !=
                  null) ...[
                const Expanded(
                  child: Center(
                    child: Text('تعذر إعداد التقرير؛ راجع الرسالة أعلاه.'),
                  ),
                ),
              ] else ...[
                const Expanded(
                  child: Center(
                    child: Text('حدد الفترة ثم اختر «عرض المطابقة».'),
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

  Widget _summary(
    InvoiceLedgerReconciliationReport report,
    List<InvoiceLedgerReconciliationRow> rows,
  ) => Card(
    elevation: 0.5,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Wrap(
        spacing: 24,
        runSpacing: 12,
        children: [
          _metric('الفواتير المعروضة', '${rows.length}'),
          _metric(
            'مطابق',
            '${rows.where((row) => row.isReconciled).length}',
            color: Colors.green.shade700,
          ),
          _metric(
            'يحتاج مراجعة',
            '${rows.where((row) => !row.isReconciled).length}',
            color: rows.any((row) => !row.isReconciled)
                ? Colors.red.shade700
                : Colors.green.shade700,
          ),
          _metric(
            'إجمالي الفواتير المعروضة',
            '${_amount(rows.fold<int>(0, (sum, row) => sum + row.totalMinor))} ${PrintUtils.currencyInArabic(report.currency)}',
          ),
        ],
      ),
    ),
  );

  Widget _metric(String label, String value, {Color? color}) => SizedBox(
    width: 200,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 4),
        Text(
          value,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
      ],
    ),
  );

  Widget _table(List<InvoiceLedgerReconciliationRow> rows) => Card(
    elevation: 0.5,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    clipBehavior: Clip.antiAlias,
    child: SingleChildScrollView(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Directionality(
          textDirection: ui.TextDirection.rtl,
          child: DataTable(
            dataRowMinHeight: 64,
            dataRowMaxHeight: 112,
            headingRowColor: WidgetStatePropertyAll(
              Theme.of(context).colorScheme.surfaceContainerHighest,
            ),
            columns: const [
              DataColumn(label: Text('رقم الفاتورة')),
              DataColumn(label: Text('تاريخ الفاتورة')),
              DataColumn(label: Text('المستأجر')),
              DataColumn(label: Text('صافي الفاتورة / القسط')),
              DataColumn(label: Text('إجمالي الفاتورة')),
              DataColumn(label: Text('مدين القيد')),
              DataColumn(label: Text('دائن القيد')),
              DataColumn(label: Text('نتيجة المطابقة')),
            ],
            rows: [
              for (final row in rows)
                DataRow(
                  cells: [
                    DataCell(Text('${row.invoiceId}')),
                    DataCell(Text(row.invoiceDate)),
                    DataCell(
                      SizedBox(
                        width: 150,
                        child: Text(
                          row.tenantName?.trim().isNotEmpty == true
                              ? row.tenantName!.trim()
                              : 'غير مرتبط',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    DataCell(
                      Text(
                        '${_amount(row.netMinor)} / '
                        '${row.installmentAmountMinor == null ? '—' : _amount(row.installmentAmountMinor!)}',
                      ),
                    ),
                    DataCell(Text(_amount(row.totalMinor))),
                    DataCell(Text(_amount(row.journalDebitMinor))),
                    DataCell(Text(_amount(row.journalCreditMinor))),
                    DataCell(
                      SizedBox(
                        width: 300,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              row.statusLabel,
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: row.isReconciled
                                    ? Colors.green.shade700
                                    : Colors.red.shade700,
                              ),
                            ),
                            if (row.issues.isNotEmpty)
                              Text(
                                row.issueSummary,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                          ],
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

  String _amount(int minor) =>
      NumberFormat('#,##0.00', 'en_US').format(minor / 100);
}
