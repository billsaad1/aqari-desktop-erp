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

class IncomeExpenseReportScreen extends StatefulWidget {
  const IncomeExpenseReportScreen({super.key});

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
    await Provider.of<ReportsProvider>(
      context,
      listen: false,
    ).loadIncomeExpenseReport(
      _startDateController.text,
      _endDateController.text,
    );
  }

  Future<void> _preview(IncomeExpenseReport report) async {
    if (!PermissionRuntime.allows('reports', AppPermissionAction.view)) return;
    try {
      final authorizationUserId = PermissionRuntime.userId;
      final authorizationRole = PermissionRuntime.role;
      final companyInfo = await DatabaseHelper.instance.getCompanyInfo();
      if (!mounted ||
          PermissionRuntime.userId != authorizationUserId ||
          PermissionRuntime.role != authorizationRole ||
          !PermissionRuntime.allows('reports', AppPermissionAction.view)) {
        return;
      }
      final bytes = await IncomeExpenseReportPdf.build(
        report: report,
        companyInfo: companyInfo,
        currency: PrintUtils.currencyInArabic(report.currency),
      );
      if (!mounted ||
          PermissionRuntime.userId != authorizationUserId ||
          PermissionRuntime.role != authorizationRole ||
          !PermissionRuntime.allows('reports', AppPermissionAction.view)) {
        return;
      }
      await PdfDocumentPreviewDialog.show(
        context: context,
        bytes: bytes,
        fileName:
            'حركة_الإيرادات_والمصروفات_${report.startDate}_${report.endDate}',
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
                        'حركة الإيرادات والمصروفات',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'مصدر التقرير هو حركات دفتر الأستاذ المرحلة على حسابات الإيرادات والمصروفات فقط؛ لا تُجمع الفواتير أو التحصيلات مرة أخرى.',
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
              if (reports.incomeExpenseErrorMessage != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: _errorBox(reports.incomeExpenseErrorMessage!),
                ),
              const SizedBox(height: 12),
              if (isCurrentReport) ...[
                _summary(report),
                const SizedBox(height: 10),
                Expanded(
                  child: report.rows.isEmpty
                      ? const Center(
                          child: Text(
                            'لا توجد حركات مرحلة على حسابات الإيرادات أو المصروفات في الفترة المحددة.',
                          ),
                        )
                      : _table(report),
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
