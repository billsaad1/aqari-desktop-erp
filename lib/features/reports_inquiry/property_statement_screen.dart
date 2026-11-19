import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/pdf_preview_dialog.dart';
import '../../core/permission_policy.dart';
import '../../core/print_utils.dart';
import '../../core/property_statement_pdf.dart';
import '../../database/database_helper.dart';
import '../../models/property_statement_report_model.dart';
import '../../providers/reports_provider.dart';

/// Read-only property statement. Every number shown comes from posted journal
/// lines carrying this property's own cost centre; anything else is disclosed
/// as a gap instead of being attributed by guess.
class PropertyStatementScreen extends StatefulWidget {
  const PropertyStatementScreen({super.key});

  @override
  State<PropertyStatementScreen> createState() =>
      _PropertyStatementScreenState();
}

class _PropertyStatementScreenState extends State<PropertyStatementScreen> {
  final _startDateController = TextEditingController(
    text: DateFormat(
      'yyyy-MM-dd',
    ).format(DateTime.now().subtract(const Duration(days: 30))),
  );
  final _endDateController = TextEditingController(
    text: DateFormat('yyyy-MM-dd').format(DateTime.now()),
  );
  int? _selectedPropertyId;

  @override
  void initState() {
    super.initState();
    PermissionRuntime.authorizationRevision.addListener(
      _onAuthorizationChanged,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !PermissionRuntime.allows('reports', AppPermissionAction.view)) {
        return;
      }
      Provider.of<ReportsProvider>(
        context,
        listen: false,
      ).loadPropertyStatementProperties();
    });
  }

  void _onAuthorizationChanged() {
    if (!mounted) return;
    final reports = Provider.of<ReportsProvider>(context, listen: false);
    if (!PermissionRuntime.allows('reports', AppPermissionAction.view)) {
      reports.clearPropertyStatement();
      setState(() => _selectedPropertyId = null);
      return;
    }
    if (!reports.propertyStatementPropertiesLoaded &&
        !reports.isPropertyStatementLoading) {
      reports.loadPropertyStatementProperties();
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

  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _loadStatement() async {
    final propertyId = _selectedPropertyId;
    final start = DateTime.tryParse(_startDateController.text);
    final end = DateTime.tryParse(_endDateController.text);
    if (propertyId == null) {
      _showMessage('اختر عقارًا أولًا');
      return;
    }
    if (start == null || end == null || start.isAfter(end)) {
      _showMessage('تحقق من صحة الفترة الزمنية');
      return;
    }
    await Provider.of<ReportsProvider>(
      context,
      listen: false,
    ).loadPropertyStatement(
      propertyId,
      _startDateController.text,
      _endDateController.text,
    );
  }

  Future<void> _selectDate(TextEditingController controller) async {
    final initial = DateTime.tryParse(controller.text) ?? DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null && mounted) {
      setState(() => controller.text = DateFormat('yyyy-MM-dd').format(picked));
      Provider.of<ReportsProvider>(
        context,
        listen: false,
      ).clearPropertyStatement();
    }
  }

  Future<void> _printStatement(
    PropertyStatementReport report, {
    required bool saveAsPdf,
  }) async {
    if (!PermissionRuntime.allows('reports', AppPermissionAction.print)) {
      _showMessage('لا تملك صلاحية طباعة أو حفظ التقارير');
      return;
    }
    try {
      final companyInfo = await DatabaseHelper.instance.getCompanyInfo();
      final bytes = await PropertyStatementPdf.build(
        report: report,
        companyInfo: companyInfo,
        currency: PrintUtils.currencyInArabic(report.currency),
      );
      if (!mounted) return;
      await PdfDocumentPreviewDialog.show(
        context: context,
        bytes: bytes,
        fileName: PrintUtils.suggestedPdfName(
          'كشف_عقار_${report.propertyId}_${report.startDate}_${report.endDate}',
        ),
        preferredIntent: saveAsPdf
            ? PdfPreviewIntent.save
            : PdfPreviewIntent.printDocument,
        permissionModule: 'reports',
      );
    } catch (error) {
      if (mounted) _showMessage('تعذر تجهيز كشف العقار: $error');
    }
  }

  String _amount(int amountMinor) =>
      NumberFormat('#,##0.00').format(amountMinor / 100);

  @override
  Widget build(BuildContext context) {
    return Consumer<ReportsProvider>(
      builder: (context, reports, child) {
        if (!PermissionRuntime.allows('reports', AppPermissionAction.view)) {
          return const Center(
            child: Text('لا تملك صلاحية عرض التقارير والاستعلامات.'),
          );
        }

        final properties = reports.propertyStatementProperties;
        Map<String, dynamic>? selectedProperty;
        for (final property in properties) {
          if (property['id'] == _selectedPropertyId) {
            selectedProperty = property;
            break;
          }
        }
        final report = reports.propertyStatementReport;
        final isCurrentReport =
            selectedProperty != null &&
            report != null &&
            report.propertyId == _selectedPropertyId &&
            report.startDate == _startDateController.text &&
            report.endDate == _endDateController.text;
        final visibleReport = isCurrentReport ? report : null;
        final canPrint = PermissionRuntime.allows(
          'reports',
          AppPermissionAction.print,
        );

        return Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'كشف حساب العقار',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text(
                'يعرض الحركات المرحلة التي تحمل مركز تكلفة هذا العقار فقط، دون إنشاء أو تعديل أي قيد. الحركات التي لا يمكن ربطها بالعقار لا تُنسب إليه؛ تظهر في بنود منفصلة أسفل الكشف.',
              ),
              const SizedBox(height: 18),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SizedBox(
                    width: 350,
                    child: DropdownButtonFormField<int>(
                      initialValue:
                          properties.any(
                            (property) =>
                                property['id'] == _selectedPropertyId,
                          )
                          ? _selectedPropertyId
                          : null,
                      isExpanded: true,
                      items: properties
                          .map(
                            (property) => DropdownMenuItem<int>(
                              value: property['id'] as int,
                              child: Text(
                                property['name']?.toString() ?? '',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(growable: false),
                      onChanged:
                          reports.isPropertyStatementLoading ||
                              properties.isEmpty
                          ? null
                          : (value) {
                              reports.clearPropertyStatement();
                              setState(() => _selectedPropertyId = value);
                            },
                      decoration: const InputDecoration(
                        labelText: 'اختر العقار',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 160,
                    child: TextFormField(
                      controller: _startDateController,
                      decoration: const InputDecoration(
                        labelText: 'من تاريخ',
                        border: OutlineInputBorder(),
                      ),
                      readOnly: true,
                      onTap: () => _selectDate(_startDateController),
                    ),
                  ),
                  SizedBox(
                    width: 160,
                    child: TextFormField(
                      controller: _endDateController,
                      decoration: const InputDecoration(
                        labelText: 'إلى تاريخ',
                        border: OutlineInputBorder(),
                      ),
                      readOnly: true,
                      onTap: () => _selectDate(_endDateController),
                    ),
                  ),
                  ElevatedButton.icon(
                    onPressed: reports.isPropertyStatementLoading
                        ? null
                        : _loadStatement,
                    icon: reports.isPropertyStatementLoading
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.search),
                    label: const Text('عرض الكشف'),
                  ),
                  ElevatedButton.icon(
                    onPressed: visibleReport != null && canPrint
                        ? () => _printStatement(visibleReport, saveAsPdf: false)
                        : null,
                    icon: const Icon(Icons.print),
                    label: const Text('طباعة'),
                  ),
                  OutlinedButton.icon(
                    onPressed: visibleReport != null && canPrint
                        ? () => _printStatement(visibleReport, saveAsPdf: true)
                        : null,
                    icon: const Icon(Icons.picture_as_pdf),
                    label: const Text('حفظ PDF'),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              if (reports.propertyStatementErrorMessage != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    reports.propertyStatementErrorMessage!,
                    style: const TextStyle(color: Colors.red),
                  ),
                ),
              Expanded(
                child: visibleReport == null
                    ? const Center(
                        child: Text('اختر عقارًا وفترة ثم اعرض الكشف'),
                      )
                    : _buildReport(visibleReport),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildReport(PropertyStatementReport report) {
    return ListView(
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  report.propertyName,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                if (report.ownerName.isNotEmpty)
                  Text('المالك: ${report.ownerName}'),
                Text(
                  report.hasCostCenter
                      ? 'مركز التكلفة: ${report.costCenterCode} - ${report.costCenterName}'
                      : 'مركز التكلفة: غير مرتبط',
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 24,
                  runSpacing: 8,
                  children: [
                    _metric('الرصيد الافتتاحي', report.openingBalanceMinor),
                    _metric('إجمالي المدين', report.totalDebitMinor),
                    _metric('إجمالي الدائن', report.totalCreditMinor),
                    _metric('الرصيد الختامي', report.closingBalanceMinor),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        if (report.gaps.isNotEmpty) ...[
          Card(
            color: Colors.amber.shade50,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'حركات لم يتم إسنادها إلى هذا العقار',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 6),
                  ...report.gaps.map(
                    (gap) => Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Text(
                        '• ${_gapLabel(gap)}: ${gap.lineCount} سطر، '
                        'مدين ${_amount(gap.debitMinor)}، '
                        'دائن ${_amount(gap.creditMinor)}',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],
        if (report.lines.isEmpty)
          const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'لا توجد حركات مرحلة لهذا العقار خلال الفترة المحددة.',
              ),
            ),
          )
        else
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columnSpacing: 16,
              headingRowHeight: 40,
              columns: const [
                DataColumn(label: Text('التاريخ')),
                DataColumn(label: Text('القيد')),
                DataColumn(label: Text('الحساب')),
                DataColumn(label: Text('البيان')),
                DataColumn(label: Text('مدين'), numeric: true),
                DataColumn(label: Text('دائن'), numeric: true),
                DataColumn(label: Text('الرصيد'), numeric: true),
              ],
              rows: report.lines
                  .map(
                    (line) => DataRow(
                      cells: [
                        DataCell(Text(line.date)),
                        DataCell(Text('${line.journalEntryId}')),
                        DataCell(
                          Text('${line.accountCode} - ${line.accountName}'),
                        ),
                        DataCell(Text(line.description)),
                        DataCell(
                          Text(
                            line.debitMinor == 0
                                ? '-'
                                : _amount(line.debitMinor),
                          ),
                        ),
                        DataCell(
                          Text(
                            line.creditMinor == 0
                                ? '-'
                                : _amount(line.creditMinor),
                          ),
                        ),
                        DataCell(Text(_amount(line.runningBalanceMinor))),
                      ],
                    ),
                  )
                  .toList(growable: false),
            ),
          ),
      ],
    );
  }

  Widget _metric(String label, int amountMinor) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
      Text(
        _amount(amountMinor),
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
      ),
    ],
  );

  String _gapLabel(PropertyStatementGap gap) => switch (gap.reason) {
    PropertyStatementGapReason.propertyWithoutCostCenter =>
      'العقار بلا مركز تكلفة',
    PropertyStatementGapReason.sharedCostCenter =>
      'مركز تكلفة مشترك مع عقارات أخرى',
    PropertyStatementGapReason.unassignedCostCenter => 'سطور بلا مركز تكلفة',
  };
}
