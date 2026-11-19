import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/account_statement_pdf.dart';
import '../../core/permission_policy.dart';
import '../../core/pdf_preview_dialog.dart';
import '../../core/print_utils.dart';
import '../../database/database_helper.dart';
import '../../models/account_statement_report_model.dart';
import '../../models/tenant_statement_account_model.dart';
import '../../providers/reports_provider.dart';

class TenantStatementScreen extends StatefulWidget {
  const TenantStatementScreen({super.key});

  @override
  State<TenantStatementScreen> createState() => _TenantStatementScreenState();
}

class _TenantStatementScreenState extends State<TenantStatementScreen> {
  final _startDateController = TextEditingController(
    text: DateFormat(
      'yyyy-MM-dd',
    ).format(DateTime.now().subtract(const Duration(days: 30))),
  );
  final _endDateController = TextEditingController(
    text: DateFormat('yyyy-MM-dd').format(DateTime.now()),
  );
  int? _selectedTenantId;

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
      ).loadTenantStatementAccounts();
    });
  }

  void _onAuthorizationChanged() {
    if (!mounted) return;
    final reports = Provider.of<ReportsProvider>(context, listen: false);
    if (!PermissionRuntime.allows('reports', AppPermissionAction.view)) {
      reports.clearTenantStatement();
      setState(() => _selectedTenantId = null);
      return;
    }
    if (!reports.tenantStatementAccountsLoaded &&
        !reports.isTenantAccountsLoading) {
      reports.loadTenantStatementAccounts();
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
    final tenantId = _selectedTenantId;
    final start = DateTime.tryParse(_startDateController.text);
    final end = DateTime.tryParse(_endDateController.text);
    if (tenantId == null) {
      _showMessage('اختر مستأجرًا أولًا');
      return;
    }
    if (start == null || end == null || start.isAfter(end)) {
      _showMessage('تحقق من صحة الفترة الزمنية');
      return;
    }
    await Provider.of<ReportsProvider>(
      context,
      listen: false,
    ).loadTenantStatement(
      tenantId,
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
      ).clearTenantStatementReport();
    }
  }

  Future<void> _printStatement(
    AccountStatementReport report,
    TenantStatementAccount tenant, {
    required bool saveAsPdf,
  }) async {
    if (!PermissionRuntime.allows('reports', AppPermissionAction.print)) {
      _showMessage('لا تملك صلاحية طباعة أو حفظ التقارير');
      return;
    }
    try {
      final companyInfo = await DatabaseHelper.instance.getCompanyInfo();
      final bytes = await AccountStatementPdf.build(
        report: report,
        companyInfo: companyInfo,
        currency: PrintUtils.currencyInArabic(report.currency),
        statementTitle: 'كشف حساب المستأجر',
        partyName: tenant.tenantName,
        accountLabel: 'حساب الذمم',
      );
      if (!mounted) return;
      await PdfDocumentPreviewDialog.show(
        context: context,
        bytes: bytes,
        fileName:
            'كشف_حساب_المستأجر_${tenant.tenantId}_${report.startDate}_${report.endDate}',
        preferredIntent: saveAsPdf
            ? PdfPreviewIntent.save
            : PdfPreviewIntent.printDocument,
        permissionModule: 'reports',
      );
    } catch (error) {
      if (mounted) _showMessage('تعذر تجهيز كشف المستأجر: $error');
    }
  }

  String _amount(double value) => NumberFormat('#,##0.00').format(value);

  @override
  Widget build(BuildContext context) {
    return Consumer<ReportsProvider>(
      builder: (context, reports, child) {
        if (!PermissionRuntime.allows('reports', AppPermissionAction.view)) {
          return const Center(
            child: Text('لا تملك صلاحية عرض التقارير والاستعلامات.'),
          );
        }

        final tenants = reports.tenantStatementAccounts;
        TenantStatementAccount? selectedTenant;
        for (final tenant in tenants) {
          if (tenant.tenantId == _selectedTenantId) {
            selectedTenant = tenant;
            break;
          }
        }
        final report = reports.tenantStatementReport;
        final isCurrentReport =
            selectedTenant != null &&
            report != null &&
            report.accountId == selectedTenant.accountId &&
            report.startDate == _startDateController.text &&
            report.endDate == _endDateController.text;
        final visibleReport = isCurrentReport ? report : null;
        final reportForActions = visibleReport;
        final tenantForActions = selectedTenant;
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
                'كشف حساب المستأجر',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text(
                'يعرض القيود المرحلة على حساب ذمم المستأجر المرتبط فقط. لا يمثل هذا الكشف بديلًا عن تفاصيل القسط أو الفاتورة، وقد لا يشمل سجلات تاريخية غير مرتبطة بدفتر الأستاذ.',
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
                          tenants.any(
                            (tenant) => tenant.tenantId == _selectedTenantId,
                          )
                          ? _selectedTenantId
                          : null,
                      isExpanded: true,
                      items: tenants
                          .map(
                            (tenant) => DropdownMenuItem<int>(
                              value: tenant.tenantId,
                              enabled: tenant.isReportable,
                              child: Text(
                                tenant.isReportable
                                    ? tenant.tenantName
                                    : '${tenant.tenantName} — لا يرتبط بحساب ذمم تفصيلي',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(growable: false),
                      onChanged:
                          reports.isTenantAccountsLoading || tenants.isEmpty
                          ? null
                          : (value) {
                              reports.clearTenantStatementReport();
                              setState(() => _selectedTenantId = value);
                            },
                      decoration: const InputDecoration(
                        labelText: 'اختر المستأجر',
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
                        reports.isTenantAccountsLoading ||
                            reports.isTenantStatementLoading
                        ? null
                        : _loadStatement,
                    icon: reports.isTenantStatementLoading
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.search),
                    label: const Text('عرض الكشف'),
                  ),
                  ElevatedButton.icon(
                    onPressed:
                        reportForActions != null &&
                            tenantForActions != null &&
                            canPrint
                        ? () => _printStatement(
                            reportForActions,
                            tenantForActions,
                            saveAsPdf: false,
                          )
                        : null,
                    icon: const Icon(Icons.print),
                    label: const Text('طباعة'),
                  ),
                  OutlinedButton.icon(
                    onPressed:
                        reportForActions != null &&
                            tenantForActions != null &&
                            canPrint
                        ? () => _printStatement(
                            reportForActions,
                            tenantForActions,
                            saveAsPdf: true,
                          )
                        : null,
                    icon: const Icon(Icons.picture_as_pdf),
                    label: const Text('حفظ PDF'),
                  ),
                ],
              ),
              if (reports.isTenantAccountsLoading)
                const LinearProgressIndicator(),
              if (reports.tenantAccountsErrorMessage != null)
                _errorPanel(
                  reports.tenantAccountsErrorMessage!,
                  () => reports.loadTenantStatementAccounts(),
                ),
              if (reports.tenantStatementErrorMessage != null)
                _errorPanel(reports.tenantStatementErrorMessage!, null),
              if (visibleReport != null && selectedTenant != null) ...[
                const SizedBox(height: 16),
                _summary(visibleReport, selectedTenant),
              ],
              const SizedBox(height: 12),
              Expanded(
                child: visibleReport == null || selectedTenant == null
                    ? Center(
                        child: reports.isTenantStatementLoading
                            ? const CircularProgressIndicator()
                            : Text(
                                reports.tenantStatementAccountsLoaded
                                    ? 'اختر مستأجرًا وفترة ثم اضغط «عرض الكشف».'
                                    : 'جارٍ تحميل المستأجرين المرتبطين بحساباتهم...',
                                textAlign: TextAlign.center,
                              ),
                      )
                    : _movementTable(visibleReport),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _errorPanel(String message, VoidCallback? onRetry) => Padding(
    padding: const EdgeInsets.only(top: 10),
    child: Row(
      children: [
        Expanded(
          child: Text(message, style: const TextStyle(color: Colors.red)),
        ),
        if (onRetry != null)
          TextButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('إعادة المحاولة'),
          ),
      ],
    ),
  );

  Widget _summary(
    AccountStatementReport report,
    TenantStatementAccount tenant,
  ) {
    final currency = PrintUtils.currencyInArabic(report.currency);
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        _summaryCard('المستأجر', tenant.tenantName),
        _summaryCard(
          'حساب الذمم',
          '${tenant.accountCode ?? ''} - ${tenant.accountName ?? ''}',
        ),
        _summaryCard(
          'الرصيد الافتتاحي',
          '${_amount(report.openingBalance)} $currency',
        ),
        _summaryCard(
          'إجمالي المدين',
          '${_amount(report.totalDebit)} $currency',
        ),
        _summaryCard(
          'إجمالي الدائن',
          '${_amount(report.totalCredit)} $currency',
        ),
        _summaryCard(
          'الرصيد الختامي',
          '${_amount(report.closingBalance)} $currency',
        ),
      ],
    );
  }

  Widget _summaryCard(String label, String value) => Card(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 4),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w700)),
        ],
      ),
    ),
  );

  Widget _movementTable(AccountStatementReport report) {
    if (report.lines.isEmpty) {
      return const Center(
        child: Text(
          'لا توجد حركات مرحلة في الفترة المحددة؛ الرصيد الافتتاحي والختامي معروضان أعلاه.',
          textAlign: TextAlign.center,
        ),
      );
    }
    return Card(
      clipBehavior: Clip.antiAlias,
      child: SingleChildScrollView(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            columns: const [
              DataColumn(label: Text('التاريخ')),
              DataColumn(label: Text('رقم القيد')),
              DataColumn(label: Text('البيان')),
              DataColumn(label: Text('مدين')),
              DataColumn(label: Text('دائن')),
              DataColumn(label: Text('الرصيد')),
            ],
            rows: report.lines
                .map(
                  (line) => DataRow(
                    cells: [
                      DataCell(Text(line.date)),
                      DataCell(Text(line.journalEntryId.toString())),
                      DataCell(
                        SizedBox(
                          width: 320,
                          child: Text(
                            line.description,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                      DataCell(Text(_amount(line.debit))),
                      DataCell(Text(_amount(line.credit))),
                      DataCell(Text(_amount(line.runningBalance))),
                    ],
                  ),
                )
                .toList(growable: false),
          ),
        ),
      ),
    );
  }
}
