import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/financial_close_readiness_pdf.dart';
import '../../core/permission_policy.dart';
import '../../core/pdf_preview_dialog.dart';
import '../../core/print_utils.dart';
import '../../database/database_helper.dart';
import '../../models/financial_close_readiness_report_model.dart';
import '../../models/internal_subledger_reconciliation_report_model.dart';
import '../../providers/reports_provider.dart';

class FinancialCloseReadinessScreen extends StatefulWidget {
  const FinancialCloseReadinessScreen({super.key});

  @override
  State<FinancialCloseReadinessScreen> createState() =>
      _FinancialCloseReadinessScreenState();
}

class _FinancialCloseReadinessScreenState
    extends State<FinancialCloseReadinessScreen> {
  final _startDateController = TextEditingController(
    text: DateFormat(
      'yyyy-MM-dd',
    ).format(DateTime(DateTime.now().year, DateTime.now().month, 1)),
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
      ).clearFinancialCloseReadinessReport();
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
    });
    Provider.of<ReportsProvider>(
      context,
      listen: false,
    ).clearFinancialCloseReadinessReport();
  }

  Future<void> _loadReport() async {
    final start = DateTime.tryParse(_startDateController.text);
    final end = DateTime.tryParse(_endDateController.text);
    if (start == null ||
        end == null ||
        DateFormat('yyyy-MM-dd').format(start) != _startDateController.text ||
        DateFormat('yyyy-MM-dd').format(end) != _endDateController.text ||
        start.isAfter(end)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تحقق من صحة فترة مراجعة الإقفال')),
      );
      return;
    }
    await Provider.of<ReportsProvider>(
      context,
      listen: false,
    ).loadFinancialCloseReadinessReport(
      _startDateController.text,
      _endDateController.text,
    );
  }

  Future<void> _preview(FinancialCloseReadinessReport report) async {
    if (!PermissionRuntime.allows('reports', AppPermissionAction.view)) return;
    final reports = Provider.of<ReportsProvider>(context, listen: false);
    final reportGeneration = reports.financialCloseReadinessGeneration;
    bool isCurrent() =>
        mounted &&
        reports.financialCloseReadinessReport == report &&
        reports.financialCloseReadinessGeneration == reportGeneration &&
        _startDateController.text == report.startDate &&
        _endDateController.text == report.endDate &&
        PermissionRuntime.allows('reports', AppPermissionAction.view);

    try {
      final authorizationUserId = PermissionRuntime.userId;
      final authorizationRole = PermissionRuntime.role;
      final companyInfo = await DatabaseHelper.instance.getCompanyInfo();
      if (!isCurrent() ||
          PermissionRuntime.userId != authorizationUserId ||
          PermissionRuntime.role != authorizationRole) {
        return;
      }
      final bytes = await FinancialCloseReadinessPdf.build(
        report: report,
        companyInfo: companyInfo,
        currency: PrintUtils.currencyInArabic(report.currency),
      );
      if (!isCurrent() ||
          PermissionRuntime.userId != authorizationUserId ||
          PermissionRuntime.role != authorizationRole) {
        return;
      }
      if (!mounted) return;
      await PdfDocumentPreviewDialog.show(
        context: context,
        bytes: bytes,
        fileName: 'مراجعة_جاهزية_الإقفال_${report.startDate}_${report.endDate}',
        preferredIntent: PdfPreviewIntent.printDocument,
        permissionModule: 'reports',
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تعذر تجهيز مراجعة الإقفال: $error')),
        );
      }
    }
  }

  String _amount(int minor) =>
      NumberFormat('#,##0.00;(#,##0.00)', 'en_US').format(minor / 100);

  @override
  Widget build(BuildContext context) {
    return Consumer<ReportsProvider>(
      builder: (context, reports, child) {
        if (!PermissionRuntime.allows('reports', AppPermissionAction.view)) {
          return const Center(
            child: Text('لا تملك صلاحية عرض التقارير والاستعلامات.'),
          );
        }
        final report = reports.financialCloseReadinessReport;
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
                        'مراجعة جاهزية الإقفال المالي',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 5),
                      const Text(
                        'فحص قراءة فقط للمسودات والقيود غير المتوازنة واتساق السجلات الفرعية مع الأستاذ ضمن الفترة. لا ينشئ التقرير قيود تصحيح أو يقفل الفترة؛ الاعتماد والإقفال يبقيان يدويين.',
                      ),
                      const SizedBox(height: 14),
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          _dateField('من تاريخ', _startDateController),
                          _dateField('إلى تاريخ', _endDateController),
                          FilledButton.icon(
                            onPressed: reports.isFinancialCloseReadinessLoading
                                ? null
                                : _loadReport,
                            icon: reports.isFinancialCloseReadinessLoading
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.fact_check_outlined),
                            label: const Text('فحص الفترة'),
                          ),
                          OutlinedButton.icon(
                            onPressed: isCurrentReport
                                ? () => _preview(report)
                                : null,
                            icon: const Icon(Icons.picture_as_pdf_outlined),
                            label: const Text('معاينة / حفظ PDF'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              if (reports.financialCloseReadinessErrorMessage != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: _messageBox(
                    reports.financialCloseReadinessErrorMessage!,
                    Colors.red.shade700,
                  ),
                ),
              const SizedBox(height: 12),
              if (isCurrentReport) ...[
                _statusBanner(report),
                const SizedBox(height: 10),
                _summaryCard(report),
                const SizedBox(height: 10),
                Expanded(child: _issuesTable(report)),
              ] else if (reports.isFinancialCloseReadinessLoading) ...[
                const Expanded(
                  child: Center(child: CircularProgressIndicator()),
                ),
              ] else if (reports.financialCloseReadinessErrorMessage !=
                  null) ...[
                const Expanded(
                  child: Center(
                    child: Text('تعذر إعداد التقرير؛ راجع الرسالة.'),
                  ),
                ),
              ] else ...[
                const Expanded(
                  child: Center(
                    child: Text('حدد الفترة ثم اختر «فحص الفترة».'),
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
    width: 210,
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

  Widget _statusBanner(FinancialCloseReadinessReport report) {
    final color = !report.isReadyForManualReview
        ? Colors.orange.shade800
        : report.requiresManualReviewAcknowledgement
        ? Colors.amber.shade900
        : Colors.green.shade700;
    final icon = !report.isReadyForManualReview ||
            report.requiresManualReviewAcknowledgement
        ? Icons.warning_amber_rounded
        : Icons.fact_check_outlined;
    final text = !report.isReadyForManualReview
        ? 'توجد قيود أو استثناءات مطابقة داخلية تحتاج معالجة يدوية قبل القفل.'
        : report.requiresManualReviewAcknowledgement
        ? 'لا توجد موانع تشغيلية، لكن توجد حركات تتطلب قرار مراجعة يدويًا وتوثيقًا عند القفل.'
        : 'اجتازت الفترة فحوص التوازن والمطابقة الداخلية الأساسية؛ لا يعني ذلك اعتماد القوائم أو تنفيذ الإقفال.';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        border: Border.all(color: color.withValues(alpha: 0.35)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: color, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  Widget _summaryCard(FinancialCloseReadinessReport report) => Card(
    elevation: 1,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Wrap(
        spacing: 28,
        runSpacing: 12,
        children: [
          _summaryValue('قيود غير مرحلة', '${report.unpostedEntries.length}'),
          _summaryValue(
            'قيود مرحلة غير متوازنة',
            '${report.unbalancedPostedEntries.length}',
          ),
          _summaryValue(
            'استثناءات مطابقة داخلية مانعة',
            '${report.blockingReconciliationCount}',
          ),
          _summaryValue(
            'استثناءات تتطلب إقرار مراجعة',
            '${report.manualReviewAcknowledgementCount}',
          ),
          _summaryValue(
            'بنود تاريخية للمراجعة',
            '${report.legacyReviewCount}',
          ),
          _summaryValue(
            'مدين المسودات',
            '${_amount(report.unpostedDebitMinor)} ${PrintUtils.currencyInArabic(report.currency)}',
          ),
          _summaryValue(
            'دائن المسودات',
            '${_amount(report.unpostedCreditMinor)} ${PrintUtils.currencyInArabic(report.currency)}',
          ),
        ],
      ),
    ),
  );

  Widget _summaryValue(String label, String value) => SizedBox(
    width: 230,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: Colors.black54)),
        const SizedBox(height: 3),
        Text(value, style: const TextStyle(fontWeight: FontWeight.bold)),
      ],
    ),
  );

  Widget _issuesTable(FinancialCloseReadinessReport report) {
    final journalIssues = [
      ...report.unpostedEntries,
      ...report.unbalancedPostedEntries,
    ];
    final reconciliationRows = report.internalReconciliation.rows
        .where((row) => !row.isLedgerMatched)
        .toList(growable: false);
    if (journalIssues.isEmpty && reconciliationRows.isEmpty) {
      return const Center(
        child: Text('لا توجد مسودات أو فروق مطابقة داخلية ظاهرة ضمن الفترة.'),
      );
    }
    return ListView(
      children: [
        if (journalIssues.isNotEmpty)
          Card(
            elevation: 1,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            child: SingleChildScrollView(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  headingRowColor: WidgetStatePropertyAll(
                    Theme.of(context).colorScheme.surfaceContainerHighest,
                  ),
                  columns: const [
                    DataColumn(label: Text('حالة المراجعة')),
                    DataColumn(label: Text('رقم القيد')),
                    DataColumn(label: Text('التاريخ')),
                    DataColumn(label: Text('البيان')),
                    DataColumn(label: Text('مدين')),
                    DataColumn(label: Text('دائن')),
                    DataColumn(label: Text('الفرق')),
                  ],
                  rows: journalIssues
                      .map(
                        (issue) => DataRow(
                          cells: [
                            DataCell(Text(issue.statusLabel)),
                            DataCell(Text('${issue.journalEntryId}')),
                            DataCell(Text(issue.entryDate)),
                            DataCell(
                              SizedBox(
                                width: 260,
                                child: Text(
                                  issue.description.isEmpty
                                      ? '—'
                                      : issue.description,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                            DataCell(Text(_amount(issue.debitMinor))),
                            DataCell(Text(_amount(issue.creditMinor))),
                            DataCell(Text(_amount(issue.differenceMinor))),
                          ],
                        ),
                      )
                      .toList(growable: false),
                ),
              ),
            ),
          ),
        if (reconciliationRows.isNotEmpty)
          Card(
            elevation: 1,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                headingRowColor: WidgetStatePropertyAll(
                  Theme.of(context).colorScheme.surfaceContainerHighest,
                ),
                columns: const [
                  DataColumn(label: Text('حالة المطابقة')),
                  DataColumn(label: Text('نوع المصدر')),
                  DataColumn(label: Text('رقم المصدر')),
                  DataColumn(label: Text('التاريخ')),
                  DataColumn(label: Text('الطرف / البيان')),
                  DataColumn(label: Text('المبلغ')),
                  DataColumn(label: Text('سبب المراجعة')),
                ],
                rows: reconciliationRows
                    .map(
                      (row) => DataRow(
                        cells: [
                          DataCell(Text(row.state.label)),
                          DataCell(Text(row.source.label)),
                          DataCell(Text('${row.sourceId}')),
                          DataCell(Text(row.sourceDate)),
                          DataCell(
                            SizedBox(
                              width: 190,
                              child: Text(
                                row.partyName,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                          DataCell(Text(_amount(row.amountMinor))),
                          DataCell(
                            SizedBox(
                              width: 280,
                              child: Text(
                                row.issueSummary,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                        ],
                      ),
                    )
                    .toList(growable: false),
              ),
            ),
          ),
        if (report.requiresManualReviewAcknowledgement)
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text(
              'لا يُخمن النظام روابط المستندات التاريخية أو هوية الطرف في القيود المباشرة. راجعها يدويًا وسجّل ملخص القرار عند قفل الفترة.',
            ),
          ),
      ],
    );
  }

  Widget _messageBox(String text, Color color) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.08),
      border: Border.all(color: color.withValues(alpha: 0.35)),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Text(text, style: TextStyle(color: color)),
  );
}
