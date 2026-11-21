import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/permission_policy.dart';
import '../../core/pdf_preview_dialog.dart';
import '../../core/print_utils.dart';
import '../../core/income_expense_report_pdf.dart';
import '../../database/database_helper.dart';
import '../../models/income_expense_report_model.dart';
import '../../providers/reports_provider.dart';
import '../../services/report_export_service.dart';

class IncomeExpenseReportScreen extends StatefulWidget {
  const IncomeExpenseReportScreen({
    super.key,
    this.companyInfoLoader,
    this.pdfBuilder,
    this.reportExportService,
  });

  final Future<Map<String, dynamic>?> Function()? companyInfoLoader;
  final Future<Uint8List> Function(
    IncomeExpenseReport report,
    Map<String, dynamic>? companyInfo,
    String currency,
  )?
  pdfBuilder;
  final ReportExportService? reportExportService;

  @override
  State<IncomeExpenseReportScreen> createState() =>
      _IncomeExpenseReportScreenState();
}

class _IncomeExpenseReportScreenState extends State<IncomeExpenseReportScreen> {
  final _startDateController = TextEditingController(
    text: DateFormat(
      'yyyy-MM-dd',
    ).format(DateTime.now().subtract(const Duration(days: 30))),
  );
  final _endDateController = TextEditingController(
    text: DateFormat('yyyy-MM-dd').format(DateTime.now()),
  );

  String _selectedCostCenterKey = 'all';

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
      _selectedCostCenterKey = 'all';
      Provider.of<ReportsProvider>(
        context,
        listen: false,
      ).clearIncomeExpenseReport();
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
        _selectedCostCenterKey = 'all';
      });
      Provider.of<ReportsProvider>(
        context,
        listen: false,
      ).clearIncomeExpenseReport();
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
    final reports = Provider.of<ReportsProvider>(context, listen: false);
    await reports.loadIncomeExpenseReport(
      _startDateController.text,
      _endDateController.text,
    );
    if (!mounted) return;
    final loadedReport = reports.incomeExpenseReport;
    if (loadedReport != null &&
        _selectedCostCenterKey != _effectiveFilterKey(loadedReport)) {
      setState(() => _selectedCostCenterKey = 'all');
    }
  }

  List<IncomeExpenseCostCenter> _availableCostCenters(
    IncomeExpenseReport? report,
  ) {
    final centers = <int, IncomeExpenseCostCenter>{
      for (final center
          in report?.costCenters ?? const <IncomeExpenseCostCenter>[])
        center.id: center,
    };
    for (final row in report?.rows ?? const <IncomeExpenseAccountRow>[]) {
      final id = row.costCenterId;
      if (id == null || centers.containsKey(id)) continue;
      final name = row.costCenterName?.trim() ?? '';
      centers[id] = IncomeExpenseCostCenter(
        id: id,
        code: row.costCenterCode?.trim() ?? '',
        name: name.isEmpty ? 'مركز غير معروف (#$id)' : name,
      );
    }
    return centers.values.toList(growable: false);
  }

  String _effectiveFilterKey(IncomeExpenseReport report) {
    final key = _selectedCostCenterKey;
    if (key == 'all' || key == 'unassigned') return key;
    if (!key.startsWith('center:')) return 'all';
    final id = int.tryParse(key.substring('center:'.length));
    return id != null &&
            _availableCostCenters(report).any((center) => center.id == id)
        ? key
        : 'all';
  }

  String _filterLabel(IncomeExpenseReport report, String key) {
    if (key == 'all') return 'كل مراكز التكلفة';
    if (key == 'unassigned') return 'غير مخصص';
    final id = int.tryParse(key.substring('center:'.length));
    if (id == null) return 'كل مراكز التكلفة';
    for (final center in _availableCostCenters(report)) {
      if (center.id == id) return center.label;
    }
    return 'مركز غير معروف (#$id)';
  }

  IncomeExpenseReport _filteredReport(IncomeExpenseReport report) {
    final key = _effectiveFilterKey(report);
    final centerId = key.startsWith('center:')
        ? int.tryParse(key.substring('center:'.length))
        : null;
    final filteredRows = report.rows
        .where((row) {
          if (key == 'all') return true;
          if (key == 'unassigned') return row.costCenterId == null;
          return centerId != null && row.costCenterId == centerId;
        })
        .toList(growable: false);
    return report.withCostCenterFilter(
      filteredRows: filteredRows,
      filterKey: key,
      filterLabel: _filterLabel(report, key),
    );
  }

  List<DropdownMenuItem<String>> _costCenterFilterItems(
    IncomeExpenseReport? report,
  ) => [
    const DropdownMenuItem(value: 'all', child: Text('كل مراكز التكلفة')),
    const DropdownMenuItem(value: 'unassigned', child: Text('غير مخصص')),
    for (final center in _availableCostCenters(report))
      DropdownMenuItem(
        value: 'center:${center.id}',
        child: Text(center.label, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
  ];

  Future<void> _preview(IncomeExpenseReport report) async {
    if (!PermissionRuntime.allows('reports', AppPermissionAction.view)) return;
    final reportsProvider = Provider.of<ReportsProvider>(
      context,
      listen: false,
    );
    final sourceReport = reportsProvider.incomeExpenseReport;
    if (sourceReport == null ||
        sourceReport.startDate != report.startDate ||
        sourceReport.endDate != report.endDate) {
      return;
    }
    final sourceGeneration = reportsProvider.incomeExpenseReportGeneration;
    bool isCurrentSource() =>
        reportsProvider.incomeExpenseReportGeneration == sourceGeneration &&
        identical(reportsProvider.incomeExpenseReport, sourceReport);

    final selectedFilterKey = report.costCenterFilterKey;
    bool isCurrentSelection() =>
        _selectedCostCenterKey == selectedFilterKey &&
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
          PermissionRuntime.userId != authorizationUserId ||
          PermissionRuntime.role != authorizationRole ||
          !isCurrentSelection() ||
          !PermissionRuntime.allows('reports', AppPermissionAction.view)) {
        return;
      }
      final currency = PrintUtils.currencyInArabic(report.currency);
      final pdfBuilder = widget.pdfBuilder;
      final bytes = pdfBuilder == null
          ? await IncomeExpenseReportPdf.build(
              report: report,
              companyInfo: companyInfo,
              currency: currency,
            )
          : await pdfBuilder(report, companyInfo, currency);
      if (!mounted ||
          !isCurrentSource() ||
          PermissionRuntime.userId != authorizationUserId ||
          PermissionRuntime.role != authorizationRole ||
          !isCurrentSelection() ||
          !PermissionRuntime.allows('reports', AppPermissionAction.view)) {
        return;
      }
      if (!mounted) return;
      await PdfDocumentPreviewDialog.show(
        context: context,
        bytes: bytes,
        fileName:
            'حركة_الإيرادات_والمصروفات_${selectedFilterKey.replaceAll(':', '_')}_${report.startDate}_${report.endDate}',
        preferredIntent: PdfPreviewIntent.printDocument,
        permissionModule: 'reports',
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('تعذر تجهيز تقرير الإيرادات والمصروفات: $error'),
          ),
        );
      }
    }
  }

  Future<void> _export(
    IncomeExpenseReport report,
    ReportExportFormat format,
  ) async {
    final reportsProvider = Provider.of<ReportsProvider>(
      context,
      listen: false,
    );
    final sourceReport = reportsProvider.incomeExpenseReport;
    final sourceGeneration = reportsProvider.incomeExpenseReportGeneration;
    final selectedFilterKey = report.costCenterFilterKey;
    final authorizationUserId = PermissionRuntime.userId;
    final authorizationRole = PermissionRuntime.role;
    bool isAuthorizedAndCurrent() =>
        mounted &&
        PermissionRuntime.userId == authorizationUserId &&
        PermissionRuntime.role == authorizationRole &&
        PermissionRuntime.allows('reports', AppPermissionAction.view) &&
        PermissionRuntime.allows('reports', AppPermissionAction.print) &&
        sourceReport != null &&
        identical(reportsProvider.incomeExpenseReport, sourceReport) &&
        reportsProvider.incomeExpenseReportGeneration == sourceGeneration &&
        _selectedCostCenterKey == selectedFilterKey &&
        report.startDate == _startDateController.text &&
        report.endDate == _endDateController.text &&
        sourceReport.startDate == report.startDate &&
        sourceReport.endDate == report.endDate;

    if (!isAuthorizedAndCurrent()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('لا تملك صلاحية تصدير هذا التقرير')),
      );
      return;
    }
    try {
      final result = await (widget.reportExportService ?? ReportExportService())
          .exportReport(
            data: ReportExportData.incomeExpense(report),
            format: format,
            isAuthorized: isAuthorizedAndCurrent,
          );
      if (!mounted) return;
      switch (result.status) {
        case ReportExportStatus.saved:
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('تم حفظ التقرير في ${result.path}')),
          );
          break;
        case ReportExportStatus.cancelled:
          break;
        case ReportExportStatus.permissionDenied:
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'انتهت صلاحية التصدير أو تغيّر التقرير؛ أعد تحميله.',
              ),
            ),
          );
          break;
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('تعذر تصدير تقرير الإيرادات والمصروفات: $error'),
          ),
        );
      }
    }
  }

  String _amount(int minor) =>
      NumberFormat('#,##0.00', 'en_US').format(minor / 100);

  @override
  Widget build(BuildContext context) {
    return Consumer<ReportsProvider>(
      builder: (context, reports, child) {
        if (!PermissionRuntime.allows('reports', AppPermissionAction.view)) {
          return const Center(
            child: Text('لا تملك صلاحية عرض التقارير والاستعلامات.'),
          );
        }
        final report = reports.incomeExpenseReport;
        final visibleReport =
            report != null &&
                report.startDate == _startDateController.text &&
                report.endDate == _endDateController.text
            ? _filteredReport(report)
            : null;

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
                        'حركة الإيرادات والمصروفات',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'المصدر حركات دفتر الأستاذ المرحلة فقط. يعرض التقرير مركز التكلفة المسجل على سطر القيد، ويُظهر الأسطر غير المسندة إلى مركز بصورة منفصلة.',
                      ),
                      const SizedBox(height: 16),
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          _dateField('من تاريخ', _startDateController),
                          _dateField('إلى تاريخ', _endDateController),
                          SizedBox(
                            width: 260,
                            child: DropdownButtonFormField<String>(
                              key: const ValueKey(
                                'incomeExpenseCostCenterFilter',
                              ),
                              isExpanded: true,
                              initialValue:
                                  visibleReport?.costCenterFilterKey ?? 'all',
                              items: _costCenterFilterItems(visibleReport),
                              onChanged: visibleReport == null
                                  ? null
                                  : (key) {
                                      if (key == null) return;
                                      setState(
                                        () => _selectedCostCenterKey = key,
                                      );
                                    },
                              decoration: const InputDecoration(
                                labelText: 'مركز التكلفة',
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                            ),
                          ),
                          FilledButton.icon(
                            onPressed: reports.isIncomeExpenseReportLoading
                                ? null
                                : _loadReport,
                            icon: reports.isIncomeExpenseReportLoading
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.summarize_outlined),
                            label: const Text('عرض التقرير'),
                          ),
                          OutlinedButton.icon(
                            onPressed: visibleReport != null
                                ? () => _preview(visibleReport)
                                : null,
                            icon: const Icon(Icons.picture_as_pdf_outlined),
                            label: const Text('معاينة التقرير'),
                          ),
                          OutlinedButton.icon(
                            onPressed:
                                visibleReport != null &&
                                    PermissionRuntime.allows(
                                      'reports',
                                      AppPermissionAction.print,
                                    )
                                ? () => _export(
                                    visibleReport,
                                    ReportExportFormat.csv,
                                  )
                                : null,
                            icon: const Icon(Icons.table_view_outlined),
                            label: const Text('تصدير CSV'),
                          ),
                          OutlinedButton.icon(
                            onPressed:
                                visibleReport != null &&
                                    PermissionRuntime.allows(
                                      'reports',
                                      AppPermissionAction.print,
                                    )
                                ? () => _export(
                                    visibleReport,
                                    ReportExportFormat.xlsx,
                                  )
                                : null,
                            icon: const Icon(Icons.grid_on_outlined),
                            label: const Text('تصدير Excel'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              if (reports.incomeExpenseErrorMessage != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: _errorBox(reports.incomeExpenseErrorMessage!),
                ),
              const SizedBox(height: 12),
              if (visibleReport != null) ...[
                _summary(visibleReport),
                const SizedBox(height: 10),
                Expanded(
                  child: visibleReport.rows.isEmpty
                      ? const Center(
                          child: Text(
                            'لا توجد حركات مرحلة وفق مركز التكلفة والفترة المحددين.',
                          ),
                        )
                      : _table(visibleReport),
                ),
              ] else if (reports.isIncomeExpenseReportLoading) ...[
                const Expanded(
                  child: Center(child: CircularProgressIndicator()),
                ),
              ] else if (reports.incomeExpenseErrorMessage != null) ...[
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

  Widget _summary(IncomeExpenseReport report) => Card(
    elevation: 0.5,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Wrap(
        spacing: 24,
        runSpacing: 12,
        children: [
          _metric('صافي الإيرادات', report.revenueNetMinor, report.currency),
          _metric('صافي المصروفات', report.expenseNetMinor, report.currency),
          _metric(
            'صافي نتيجة الفترة',
            report.netResultMinor,
            report.currency,
            color: report.netResultMinor >= 0
                ? Colors.green.shade700
                : Colors.red.shade700,
          ),
          _metric('مدين الإيرادات', report.revenueDebitMinor, report.currency),
          _metric('دائن الإيرادات', report.revenueCreditMinor, report.currency),
          _metric('مدين المصروفات', report.expenseDebitMinor, report.currency),
          _metric('دائن المصروفات', report.expenseCreditMinor, report.currency),
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

  Widget _table(IncomeExpenseReport report) => Card(
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
              DataColumn(label: Text('النوع')),
              DataColumn(label: Text('مركز التكلفة')),
              DataColumn(label: Text('رمز الحساب')),
              DataColumn(label: Text('اسم الحساب')),
              DataColumn(label: Text('مدين'), numeric: true),
              DataColumn(label: Text('دائن'), numeric: true),
              DataColumn(label: Text('الصافي'), numeric: true),
            ],
            rows: [
              for (final row in report.rows)
                DataRow(
                  cells: [
                    DataCell(
                      Text(row.accountType == 'Revenue' ? 'إيراد' : 'مصروف'),
                    ),
                    DataCell(Text(row.costCenterLabel)),
                    DataCell(Text(row.accountCode)),
                    DataCell(Text(row.accountName)),
                    DataCell(Text(_amount(row.debitMinor))),
                    DataCell(Text(_amount(row.creditMinor))),
                    DataCell(Text(_amount(row.netMinor))),
                  ],
                ),
              DataRow(
                color: WidgetStatePropertyAll(
                  Theme.of(context).colorScheme.surfaceContainerHighest,
                ),
                cells: [
                  const DataCell(Text('ملخص')),
                  const DataCell(Text('')),
                  const DataCell(Text('')),
                  const DataCell(Text('صافي نتيجة الفترة')),
                  DataCell(
                    Text(
                      _amount(
                        report.revenueDebitMinor + report.expenseDebitMinor,
                      ),
                    ),
                  ),
                  DataCell(
                    Text(
                      _amount(
                        report.revenueCreditMinor + report.expenseCreditMinor,
                      ),
                    ),
                  ),
                  DataCell(Text(_amount(report.netResultMinor))),
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
