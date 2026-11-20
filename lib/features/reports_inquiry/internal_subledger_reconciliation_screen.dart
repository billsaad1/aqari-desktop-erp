import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/internal_subledger_reconciliation_pdf.dart';
import '../../core/pdf_preview_dialog.dart';
import '../../core/permission_policy.dart';
import '../../core/print_utils.dart';
import '../../database/database_helper.dart';
import '../../models/internal_subledger_reconciliation_report_model.dart';

class InternalSubledgerReconciliationScreen extends StatefulWidget {
  const InternalSubledgerReconciliationScreen({
    super.key,
    this.reportLoader,
    this.companyInfoLoader,
    this.pdfBuilder,
  });

  final Future<InternalSubledgerReconciliationReport> Function(
    String startDate,
    String endDate,
  )?
  reportLoader;
  final Future<Map<String, dynamic>?> Function()? companyInfoLoader;
  final Future<Uint8List> Function(
    InternalSubledgerReconciliationReport report,
    List<InternalSubledgerReconciliationRow> rows,
    Map<String, dynamic>? companyInfo,
    String currency,
  )?
  pdfBuilder;

  @override
  State<InternalSubledgerReconciliationScreen> createState() =>
      _InternalSubledgerReconciliationScreenState();
}

class _InternalSubledgerReconciliationScreenState
    extends State<InternalSubledgerReconciliationScreen> {
  late final TextEditingController _startDateController;
  late final TextEditingController _endDateController;
  InternalSubledgerReconciliationReport? _report;
  String? _error;
  String _statusFilter = 'all';
  bool _loading = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    final today = DateTime.now();
    _startDateController = TextEditingController(
      text: DateFormat('yyyy-MM-dd').format(DateTime(today.year, today.month, 1)),
    );
    _endDateController = TextEditingController(
      text: DateFormat('yyyy-MM-dd').format(today),
    );
    PermissionRuntime.authorizationRevision.addListener(
      _onAuthorizationChanged,
    );
  }

  void _onAuthorizationChanged() {
    if (!mounted) return;
    _generation++;
    _report = null;
    _error = null;
    _loading = false;
    _statusFilter = 'all';
    setState(() {});
  }

  @override
  void dispose() {
    PermissionRuntime.authorizationRevision.removeListener(
      _onAuthorizationChanged,
    );
    _startDateController.dispose();
    _endDateController.dispose();
    _generation++;
    super.dispose();
  }

  Future<void> _selectDate(TextEditingController controller) async {
    final initial = DateTime.tryParse(controller.text) ?? DateTime.now();
    final selected = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (selected == null || !mounted) return;
    setState(() {
      controller.text = DateFormat('yyyy-MM-dd').format(selected);
      _report = null;
      _error = null;
      _statusFilter = 'all';
      _generation++;
    });
  }

  bool _validDateRange() {
    final start = DateTime.tryParse(_startDateController.text);
    final end = DateTime.tryParse(_endDateController.text);
    return start != null &&
        end != null &&
        DateFormat('yyyy-MM-dd').format(start) == _startDateController.text &&
        DateFormat('yyyy-MM-dd').format(end) == _endDateController.text &&
        !start.isAfter(end);
  }

  Future<void> _loadReport() async {
    if (!PermissionRuntime.allows('reports', AppPermissionAction.view)) return;
    if (!_validDateRange()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تحقق من صحة فترة المطابقة')),
      );
      return;
    }
    final generation = ++_generation;
    final userId = PermissionRuntime.userId;
    final role = PermissionRuntime.role;
    final start = _startDateController.text;
    final end = _endDateController.text;
    setState(() {
      _loading = true;
      _report = null;
      _error = null;
      _statusFilter = 'all';
    });
    try {
      final loader = widget.reportLoader;
      final report = loader == null
          ? await DatabaseHelper.instance
                .getInternalSubledgerReconciliationReport(
                  startDate: start,
                  endDate: end,
                )
          : await loader(start, end);
      if (!_isCurrentRequest(generation, userId, role, start, end)) return;
      setState(() => _report = report);
    } catch (error) {
      if (!_isCurrentRequest(generation, userId, role, start, end)) return;
      setState(() => _error = 'تعذرت قراءة المطابقة الداخلية: $error');
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  bool _isCurrentRequest(
    int generation,
    int? userId,
    String? role,
    String start,
    String end,
  ) =>
      mounted &&
      generation == _generation &&
      PermissionRuntime.userId == userId &&
      PermissionRuntime.role == role &&
      start == _startDateController.text &&
      end == _endDateController.text &&
      PermissionRuntime.allows('reports', AppPermissionAction.view);

  List<InternalSubledgerReconciliationRow> _visibleRows(
    InternalSubledgerReconciliationReport report,
  ) => report.rows.where((row) {
    return switch (_statusFilter) {
      'matched' => row.isLedgerMatched,
      'review' => !row.isLedgerMatched,
      'unallocated' => row.unallocatedMinor > 0 ||
          (row.allocationStatus != null &&
              row.allocationStatus != 'مخصص بالكامل' &&
              row.allocationStatus != 'مرتبط بمصدر قبض صالح'),
      _ => true,
    };
  }).toList(growable: false);

  String get _filterLabel => switch (_statusFilter) {
    'matched' => 'مطابق مع الأستاذ',
    'review' => 'يحتاج مراجعة',
    'unallocated' => 'غير مخصص أو بلا مصدر',
    _ => 'كل الحالات',
  };

  String _amount(int minor) =>
      NumberFormat('#,##0.00;(#,##0.00)', 'en_US').format(minor / 100);

  Future<void> _preview(
    InternalSubledgerReconciliationReport report,
    List<InternalSubledgerReconciliationRow> rows,
  ) async {
    if (!PermissionRuntime.allows('reports', AppPermissionAction.view) ||
        !identical(_report, report)) {
      return;
    }
    final generation = _generation;
    final userId = PermissionRuntime.userId;
    final role = PermissionRuntime.role;
    final filter = _statusFilter;
    try {
      final companyInfoLoader =
          widget.companyInfoLoader ?? DatabaseHelper.instance.getCompanyInfo;
      final companyInfo = await companyInfoLoader();
      if (!_isCurrentRequest(
            generation,
            userId,
            role,
            report.startDate,
            report.endDate,
          ) ||
          !identical(_report, report) ||
          _statusFilter != filter) {
        return;
      }
      final currency = PrintUtils.currencyInArabic(report.currency);
      final pdfBuilder = widget.pdfBuilder;
      final bytes = pdfBuilder == null
          ? await InternalSubledgerReconciliationPdf.build(
              report: report,
              rows: rows,
              filterLabel: _filterLabel,
              companyInfo: companyInfo,
              currency: currency,
            )
          : await pdfBuilder(report, rows, companyInfo, currency);
      if (!_isCurrentRequest(
            generation,
            userId,
            role,
            report.startDate,
            report.endDate,
          ) ||
          !identical(_report, report) ||
          _statusFilter != filter) {
        return;
      }
      if (!mounted) return;
      await PdfDocumentPreviewDialog.show(
        context: context,
        bytes: bytes,
        fileName:
            'المطابقة_الداخلية_للسجلات_الفرعية_${report.startDate}_${report.endDate}',
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
    if (!PermissionRuntime.allows('reports', AppPermissionAction.view)) {
      return const Center(
        child: Text('لا تملك صلاحية عرض التقارير والاستعلامات.'),
      );
    }
    final report = _report != null &&
            _report!.startDate == _startDateController.text &&
            _report!.endDate == _endDateController.text
        ? _report
        : null;
    final List<InternalSubledgerReconciliationRow> rows = report == null
        ? const <InternalSubledgerReconciliationRow>[]
        : _visibleRows(report);
    return Padding(
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
                    'مطابقة السجلات الفرعية مع دفتر الأستاذ',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'فحص داخلي للروابط الرقمية بين الفواتير والقبض والاستردادات والإشعارات الدائنة وتسويات المالك وقيود الذمم. يميز سلامة قيد الأستاذ عن تخصيص القبض. لا يخمّن الربط من الوصف أو المبلغ، ولا ينشئ أرصدة افتتاحية أو قيود تسوية.',
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      _dateButton('من', _startDateController),
                      _dateButton('إلى', _endDateController),
                      FilledButton.icon(
                        onPressed: _loading ? null : _loadReport,
                        icon: _loading
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.compare_arrows),
                        label: Text(_loading ? 'جارٍ الفحص...' : 'فحص الفترة'),
                      ),
                      if (report != null)
                        OutlinedButton.icon(
                          onPressed: () => _preview(report, rows),
                          icon: const Icon(Icons.picture_as_pdf_outlined),
                          label: const Text('معاينة / طباعة PDF'),
                        ),
                      if (report != null)
                        DropdownButton<String>(
                          value: _statusFilter,
                          onChanged: (value) {
                            if (value != null) {
                              setState(() => _statusFilter = value);
                            }
                          },
                          items: const [
                            DropdownMenuItem(
                              value: 'all',
                              child: Text('كل الحالات'),
                            ),
                            DropdownMenuItem(
                              value: 'matched',
                              child: Text('مطابق مع الأستاذ'),
                            ),
                            DropdownMenuItem(
                              value: 'review',
                              child: Text('يحتاج مراجعة'),
                            ),
                            DropdownMenuItem(
                              value: 'unallocated',
                              child: Text('غير مخصص / بلا مصدر'),
                            ),
                          ],
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'هذا تقرير مطابقة دفترية داخلية، وليس مطابقة بنكية أو خارجية. القيد المرحّل لا يثبت حركة النقد لدى البنك. قد تبقى الأرصدة الافتتاحية غير الممثلة بقيود أو البيانات التاريخية غير المفصلة بحاجة إلى مراجعة يدوية.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            _message(_error!, Colors.red.shade700),
          ],
          const SizedBox(height: 10),
          if (_loading)
            const Expanded(child: Center(child: CircularProgressIndicator()))
          else if (report == null && _error == null)
            const Expanded(
              child: Center(child: Text('اختر الفترة ثم اضغط «فحص الفترة».')),
            )
          else if (report != null) ...[
            _summary(report),
            const SizedBox(height: 10),
            if (rows.isEmpty)
              const Expanded(
                child: Center(child: Text('لا توجد سجلات تطابق المرشح الحالي.')),
              )
            else
              Expanded(child: _table(rows)),
          ] else
            const Expanded(child: Center(child: Text('تعذر إعداد التقرير.'))),
        ],
      ),
    );
  }

  Widget _dateButton(String label, TextEditingController controller) =>
      OutlinedButton.icon(
        onPressed: _loading ? null : () => _selectDate(controller),
        icon: const Icon(Icons.calendar_month_outlined),
        label: Text('$label: ${controller.text}'),
      );

  Widget _summary(InternalSubledgerReconciliationReport report) => Card(
    elevation: 1,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Wrap(
        spacing: 22,
        runSpacing: 10,
        children: [
          _metric('السجلات المعروضة', '${report.rows.length}'),
          _metric('مطابق مع الأستاذ', '${report.matchedCount}'),
          _metric('بحاجة لمراجعة', '${report.reviewCount}'),
          _metric(
            'قيمة غير مخصصة / بلا مصدر',
            '${_amount(report.unallocatedMinor)} ${report.currency}',
          ),
          _metric('تاريخي للمراجعة', '${report.legacyReviewCount}'),
          _metric('قيود مباشرة على حسابات فرعية', '${report.directJournalCount}'),
        ],
      ),
    ),
  );

  Widget _metric(String label, String value) => SizedBox(
    width: 190,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: Colors.black54)),
        const SizedBox(height: 3),
        Text(value, style: const TextStyle(fontWeight: FontWeight.bold)),
      ],
    ),
  );

  Widget _table(List<InternalSubledgerReconciliationRow> rows) => Card(
    elevation: 1,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    child: SingleChildScrollView(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          headingRowColor: WidgetStatePropertyAll(
            Theme.of(context).colorScheme.surfaceContainerHighest,
          ),
          columns: const [
            DataColumn(label: Text('نوع المصدر')),
            DataColumn(label: Text('رقم السجل')),
            DataColumn(label: Text('التاريخ')),
            DataColumn(label: Text('الطرف / البيان')),
            DataColumn(label: Text('المبلغ')),
            DataColumn(label: Text('القيد / تاريخه')),
            DataColumn(label: Text('حالة الأستاذ')),
            DataColumn(label: Text('التخصيص')),
            DataColumn(label: Text('تفاصيل المراجعة')),
          ],
          rows: rows.map((row) {
            final matched = row.isLedgerMatched;
            final stateColor = matched
                ? Colors.green.shade700
                : row.state == InternalSubledgerRowState.notPosted
                ? Colors.orange.shade800
                : Colors.red.shade700;
            final journalText = row.journalEntryId == null
                ? '—'
                : '#${row.journalEntryId}${row.journalDate == null ? '' : '\n${row.journalDate}'}';
            return DataRow(
              cells: [
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
                DataCell(Text(journalText, textAlign: TextAlign.center)),
                DataCell(
                  Text(
                    row.state.label,
                    style: TextStyle(
                      color: stateColor,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                DataCell(Text(row.allocationStatus ?? '—')),
                DataCell(
                  SizedBox(
                    width: 250,
                    child: Text(
                      row.issueSummary.isEmpty ? '—' : row.issueSummary,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
            );
          }).toList(growable: false),
        ),
      ),
    ),
  );

  Widget _message(String text, Color color) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.08),
      border: Border.all(color: color.withValues(alpha: 0.25)),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Text(text, style: TextStyle(color: color)),
  );
}
