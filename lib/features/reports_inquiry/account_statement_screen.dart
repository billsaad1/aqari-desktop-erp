import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/account_statement_pdf.dart';
import '../../core/erp_data_table.dart';
import '../../core/permission_policy.dart';
import '../../core/pdf_preview_dialog.dart';
import '../../core/print_utils.dart';
import '../../database/database_helper.dart';
import '../../models/account_statement_report_model.dart';
import '../../providers/accounting_provider.dart';
import '../../providers/reports_provider.dart';

class AccountStatementScreen extends StatefulWidget {
  const AccountStatementScreen({super.key});

  @override
  State<AccountStatementScreen> createState() => _AccountStatementScreenState();
}

class _AccountStatementScreenState extends State<AccountStatementScreen> {
  final _startDateController = TextEditingController(
    text: DateFormat(
      'yyyy-MM-dd',
    ).format(DateTime.now().subtract(const Duration(days: 30))),
  );
  final _endDateController = TextEditingController(
    text: DateFormat('yyyy-MM-dd').format(DateTime.now()),
  );
  int? _selectedAccountId;

  @override
  void initState() {
    super.initState();
    PermissionRuntime.authorizationRevision.addListener(
      _onAuthorizationChanged,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Provider.of<AccountingProvider>(context, listen: false).loadAccounts();
    });
  }

  void _onAuthorizationChanged() {
    if (!mounted) return;
    if (!PermissionRuntime.allows('reports', AppPermissionAction.view)) {
      Provider.of<ReportsProvider>(
        context,
        listen: false,
      ).clearAccountStatement();
      setState(() => _selectedAccountId = null);
      return;
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

  void _loadStatement() {
    final accountId = _selectedAccountId;
    final start = DateTime.tryParse(_startDateController.text);
    final end = DateTime.tryParse(_endDateController.text);
    if (accountId == null) {
      _showMessage('اختر حسابًا تفصيليًا أولًا');
      return;
    }
    if (start == null || end == null || start.isAfter(end)) {
      _showMessage('تحقق من صحة الفترة الزمنية');
      return;
    }
    Provider.of<ReportsProvider>(context, listen: false).loadAccountStatement(
      accountId,
      _startDateController.text,
      _endDateController.text,
    );
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
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
      ).clearAccountStatement();
    }
  }

  Future<void> _printStatement(
    AccountStatementReport report, {
    required bool saveAsPdf,
  }) async {
    if (!PermissionRuntime.allows('reports', AppPermissionAction.print)) {
      _showMessage('لا تملك صلاحية طباعة أو حفظ التقارير');
      return;
    }
    try {
      final companyInfo = await DatabaseHelper.instance.getCompanyInfo();
      final currency = PrintUtils.currencyInArabic(report.currency);
      final bytes = await AccountStatementPdf.build(
        report: report,
        companyInfo: companyInfo,
        currency: currency,
      );
      if (!mounted) return;
      await PdfDocumentPreviewDialog.show(
        context: context,
        bytes: bytes,
        fileName: 'كشف_دفتر_الأستاذ_${report.accountCode}_${report.startDate}',
        preferredIntent: saveAsPdf
            ? PdfPreviewIntent.save
            : PdfPreviewIntent.printDocument,
        permissionModule: 'reports',
      );
    } catch (error) {
      if (mounted) _showMessage('تعذر تجهيز كشف دفتر الأستاذ: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer2<ReportsProvider, AccountingProvider>(
      builder: (context, reportsProv, accProv, child) {
        if (!PermissionRuntime.allows('reports', AppPermissionAction.view)) {
          return const Center(
            child: Text('لا تملك صلاحية عرض التقارير والاستعلامات.'),
          );
        }
        final detailAccounts = accProv.detailAccounts;
        final selectedAccountExists = detailAccounts.any(
          (account) => (account['id'] as num?)?.toInt() == _selectedAccountId,
        );
        final report = reportsProv.accountStatementReport;
        final isCurrentReport =
            report != null &&
            selectedAccountExists &&
            report.accountId == _selectedAccountId &&
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
                'كشف حساب دفتر الأستاذ',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text(
                'يعرض هذا الكشف القيود المرحلة للحساب التفصيلي فقط؛ ولا يمثل كشف تحصيل أو رصيد فاتورة/قسط.',
              ),
              const SizedBox(height: 20),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SizedBox(
                    width: 390,
                    child: DropdownButtonFormField<int>(
                      initialValue: selectedAccountExists
                          ? _selectedAccountId
                          : null,
                      isExpanded: true,
                      items: detailAccounts
                          .map(
                            (account) => DropdownMenuItem<int>(
                              value: (account['id'] as num).toInt(),
                              child: Text(
                                '${account['code']} - ${account['name']}',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(growable: false),
                      onChanged: accProv.isLoading
                          ? null
                          : (value) {
                              Provider.of<ReportsProvider>(
                                context,
                                listen: false,
                              ).clearAccountStatement();
                              setState(() => _selectedAccountId = value);
                            },
                      decoration: const InputDecoration(
                        labelText: 'اختر الحساب التفصيلي',
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
                    onPressed:
                        accProv.isLoading || reportsProv.isStatementLoading
                        ? null
                        : _loadStatement,
                    icon: const Icon(Icons.search),
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
              if (accProv.errorMessage != null) ...[
                const SizedBox(height: 8),
                Text(
                  accProv.errorMessage!,
                  style: const TextStyle(color: Colors.red),
                ),
              ],
              if (reportsProv.statementErrorMessage != null) ...[
                const SizedBox(height: 8),
                Text(
                  reportsProv.statementErrorMessage!,
                  style: const TextStyle(color: Colors.red),
                ),
              ],
              const SizedBox(height: 16),
              if (accProv.isLoading)
                const Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 12),
                      Text('جارٍ تحميل الحسابات التفصيلية...'),
                    ],
                  ),
                )
              else if (reportsProv.isStatementLoading)
                const Expanded(
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (visibleReport == null)
                const Expanded(
                  child: Center(
                    child: Text('اختر الحساب والفترة ثم اضغط «عرض الكشف».'),
                  ),
                )
              else
                Expanded(child: _buildReportTable(visibleReport)),
            ],
          ),
        );
      },
    );
  }

  Widget _buildReportTable(AccountStatementReport report) {
    final summaries = [
      ('الرصيد الافتتاحي', report.openingBalance),
      ('إجمالي المدين', report.totalDebit),
      ('إجمالي الدائن', report.totalCredit),
      ('الرصيد الختامي', report.closingBalance),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'العملة: ${PrintUtils.currencyInArabic(report.currency)}',
          textAlign: TextAlign.right,
          style: Theme.of(context).textTheme.labelLarge,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: summaries
              .map(
                (summary) => SizedBox(
                  width: 210,
                  child: Card(
                    elevation: 1,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            summary.$1,
                            style: Theme.of(context).textTheme.labelMedium,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            summary.$2.toStringAsFixed(2),
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              )
              .toList(growable: false),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: SingleChildScrollView(
            child: ErpDataTable(
              columns: const [
                DataColumn(label: Text('التاريخ')),
                DataColumn(label: Text('رقم القيد')),
                DataColumn(label: Text('البيان')),
                DataColumn(label: Text('مدين')),
                DataColumn(label: Text('دائن')),
                DataColumn(label: Text('الرصيد الجاري')),
              ],
              rows: [
                DataRow(
                  cells: [
                    const DataCell(Text('')),
                    const DataCell(Text('')),
                    const DataCell(Text('الرصيد الافتتاحي')),
                    const DataCell(Text('')),
                    const DataCell(Text('')),
                    DataCell(Text(report.openingBalance.toStringAsFixed(2))),
                  ],
                ),
                ...report.lines.map(
                  (line) => DataRow(
                    cells: [
                      DataCell(Text(line.date)),
                      DataCell(Text(line.journalEntryId.toString())),
                      DataCell(Text(line.description)),
                      DataCell(Text(line.debit.toStringAsFixed(2))),
                      DataCell(Text(line.credit.toStringAsFixed(2))),
                      DataCell(Text(line.runningBalance.toStringAsFixed(2))),
                    ],
                  ),
                ),
                DataRow(
                  cells: [
                    const DataCell(Text('')),
                    const DataCell(Text('')),
                    const DataCell(Text('إجمالي الفترة')),
                    DataCell(Text(report.totalDebit.toStringAsFixed(2))),
                    DataCell(Text(report.totalCredit.toStringAsFixed(2))),
                    DataCell(Text(report.closingBalance.toStringAsFixed(2))),
                  ],
                ),
              ],
            ),
          ),
        ),
        if (!report.hasActivity)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              'لا توجد حركات مرحلة في الفترة؛ الرصيد الافتتاحي والختامي ما زالا معروضين.',
            ),
          ),
      ],
    );
  }
}
