import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/pdf_preview_dialog.dart';
import '../../core/permission_policy.dart';
import '../../core/print_utils.dart';
import '../../database/database_helper.dart';

class OwnerSettlementScreen extends StatefulWidget {
  const OwnerSettlementScreen({super.key});

  @override
  State<OwnerSettlementScreen> createState() => _OwnerSettlementScreenState();
}

class _OwnerSettlementScreenState extends State<OwnerSettlementScreen> {
  final _formKey = GlobalKey<FormState>();
  final _amountController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _dateController = TextEditingController(
    text: DateFormat('yyyy-MM-dd').format(DateTime.now()),
  );

  List<Map<String, dynamic>> _owners = const [];
  List<Map<String, dynamic>> _cashAccounts = const [];
  int? _selectedOwnerId;
  int? _selectedCashAccountId;
  int? _availableBalanceMinor;
  bool _isLoading = true;
  bool _isSaving = false;
  String? _error;
  int _balanceRequestId = 0;
  int? _authorizationUserId;
  String? _authorizationRole;

  bool get _canView =>
      PermissionRuntime.allows('accounting', AppPermissionAction.view);
  bool get _canPost =>
      PermissionRuntime.allows('accounting', AppPermissionAction.post);
  bool get _canPrint =>
      PermissionRuntime.allows('accounting', AppPermissionAction.print);

  Map<String, dynamic>? get _selectedOwner {
    for (final owner in _owners) {
      if ((owner['id'] as num).toInt() == _selectedOwnerId) return owner;
    }
    return null;
  }

  Map<String, dynamic>? get _selectedCashAccount {
    for (final account in _cashAccounts) {
      if ((account['id'] as num).toInt() == _selectedCashAccountId) {
        return account;
      }
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _authorizationUserId = PermissionRuntime.userId;
    _authorizationRole = PermissionRuntime.role;
    PermissionRuntime.authorizationRevision.addListener(
      _onAuthorizationChanged,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _canView) _loadOptions();
    });
  }

  @override
  void dispose() {
    PermissionRuntime.authorizationRevision.removeListener(
      _onAuthorizationChanged,
    );
    _amountController.dispose();
    _descriptionController.dispose();
    _dateController.dispose();
    super.dispose();
  }

  void _onAuthorizationChanged() {
    if (!mounted) return;
    final identityChanged =
        _authorizationUserId != PermissionRuntime.userId ||
        _authorizationRole != PermissionRuntime.role;
    _authorizationUserId = PermissionRuntime.userId;
    _authorizationRole = PermissionRuntime.role;
    if (identityChanged) {
      _balanceRequestId++;
      setState(() {
        _owners = const [];
        _cashAccounts = const [];
        _selectedOwnerId = null;
        _selectedCashAccountId = null;
        _availableBalanceMinor = null;
        _error = null;
        _isLoading = _canView;
      });
      if (_canView) _loadOptions();
      return;
    }
    if (!_canView) {
      _balanceRequestId++;
      setState(() {
        _owners = const [];
        _cashAccounts = const [];
        _selectedOwnerId = null;
        _selectedCashAccountId = null;
        _availableBalanceMinor = null;
        _isLoading = false;
        _error = null;
      });
      return;
    }
    if (_owners.isEmpty && !_isLoading) {
      _loadOptions();
    } else {
      setState(() {});
    }
  }

  Future<void> _loadOptions() async {
    final userId = PermissionRuntime.userId;
    final role = PermissionRuntime.role;
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        DatabaseHelper.instance.getOwnerSettlementOwners(),
        DatabaseHelper.instance.getOwnerSettlementCashAccounts(),
      ]);
      if (!mounted ||
          !_canView ||
          PermissionRuntime.userId != userId ||
          PermissionRuntime.role != role) {
        return;
      }
      setState(() {
        _owners = results[0];
        _cashAccounts = results[1];
        _isLoading = false;
        if (!_owners.any(
          (owner) => (owner['id'] as num).toInt() == _selectedOwnerId,
        )) {
          _selectedOwnerId = null;
          _availableBalanceMinor = null;
        }
        if (!_cashAccounts.any(
          (account) => (account['id'] as num).toInt() == _selectedCashAccountId,
        )) {
          _selectedCashAccountId = null;
        }
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = 'تعذر تحميل خيارات سداد الملاك: $error';
      });
    }
  }

  Future<void> _loadOwnerBalance(int? ownerId) async {
    final requestId = ++_balanceRequestId;
    final userId = PermissionRuntime.userId;
    final role = PermissionRuntime.role;
    if (mounted) setState(() => _availableBalanceMinor = null);
    if (ownerId == null) return;
    try {
      final balance = await DatabaseHelper.instance
          .getOwnerSettlementBalanceMinor(ownerId);
      if (!mounted ||
          requestId != _balanceRequestId ||
          ownerId != _selectedOwnerId ||
          PermissionRuntime.userId != userId ||
          PermissionRuntime.role != role) {
        return;
      }
      setState(() => _availableBalanceMinor = balance);
    } catch (error) {
      if (!mounted || requestId != _balanceRequestId) return;
      setState(() => _availableBalanceMinor = null);
      _showMessage('تعذر قراءة الرصيد الدائن للمالك: $error');
    }
  }

  String _westernDigits(String value) =>
      value.replaceAllMapped(RegExp(r'[٠-٩۰-۹]'), (match) {
        final code = match.group(0)!.codeUnitAt(0);
        final digit = code >= 0x06f0 ? code - 0x06f0 : code - 0x0660;
        return String.fromCharCode(0x30 + digit);
      });

  int? _parseAmountMinor(String input) {
    final normalized = _westernDigits(
      input.trim().replaceAll(',', '').replaceAll('٬', '').replaceAll('٫', '.'),
    );
    if (!RegExp(r'^\d+(?:\.\d{1,2})?$').hasMatch(normalized)) return null;
    final parts = normalized.split('.');
    final whole = int.tryParse(parts.first);
    final fraction = parts.length == 1 ? '00' : parts[1].padRight(2, '0');
    final fractional = int.tryParse(fraction);
    if (whole == null || fractional == null) return null;
    return whole * 100 + fractional;
  }

  String _formatMinor(int minor) =>
      NumberFormat('#,##0.00').format(minor / 100.0);

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _pickDate() async {
    final parsed = DateTime.tryParse(_dateController.text) ?? DateTime.now();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final initial = parsed.isAfter(today) ? today : parsed;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2000),
      lastDate: today,
    );
    if (picked != null && mounted) {
      setState(
        () => _dateController.text = DateFormat('yyyy-MM-dd').format(picked),
      );
    }
  }

  Future<void> _postSettlement() async {
    if (_isSaving || !_canPost) return;
    final userId = PermissionRuntime.userId;
    final role = PermissionRuntime.role;
    final form = _formKey.currentState;
    if (form == null || !form.validate()) return;
    final owner = _selectedOwner;
    final cashAccount = _selectedCashAccount;
    final amountMinor = _parseAmountMinor(_amountController.text);
    if (owner == null || cashAccount == null || amountMinor == null) {
      _showMessage('اختر المالك وحساب الصندوق وأدخل مبلغًا صحيحًا');
      return;
    }
    final available = _availableBalanceMinor;
    if (available == null) {
      _showMessage('انتظر حتى يكتمل التحقق من رصيد المالك');
      return;
    }
    if (amountMinor > available) {
      _showMessage('مبلغ السداد يتجاوز الرصيد الدائن المتاح للمالك');
      return;
    }

    setState(() => _isSaving = true);
    late final int voucherId;
    try {
      voucherId = await DatabaseHelper.instance.insertOwnerSettlementVoucher(
        ownerId: _selectedOwnerId!,
        amountMinor: amountMinor,
        settlementDate: _dateController.text,
        cashAccountId: _selectedCashAccountId!,
        description: _descriptionController.text.trim(),
      );
    } catch (error) {
      if (mounted) {
        setState(() => _isSaving = false);
        _showMessage('لم يُرحّل سند سداد المالك: $error');
      }
      return;
    }

    if (!mounted ||
        PermissionRuntime.userId != userId ||
        PermissionRuntime.role != role) {
      return;
    }
    setState(() => _isSaving = false);
    _showMessage('تم ترحيل سند سداد المالك رقم $voucherId');
    await _loadOwnerBalance(_selectedOwnerId);

    try {
      final pdfBytes = await PrintUtils.buildVoucherPdf(
        voucherType: 'سند صرف مستحقات مالك',
        voucherNo: voucherId,
        date: _dateController.text,
        targetName: owner['name']?.toString(),
        amount: amountMinor / 100.0,
        paymentMethod: null,
        accountName:
            '${cashAccount['name']} (${cashAccount['code']}) / ${owner['owner_account_name']}',
        description: _descriptionController.text.trim(),
      );
      if (!mounted ||
          !_canView ||
          PermissionRuntime.userId != userId ||
          PermissionRuntime.role != role) {
        return;
      }
      await PdfDocumentPreviewDialog.show(
        context: context,
        bytes: pdfBytes,
        fileName: 'سند_صرف_مستحقات_مالك_$voucherId',
        preferredIntent: PdfPreviewIntent.printDocument,
        permissionModule: 'accounting',
      );
    } catch (error) {
      if (mounted) {
        _showMessage('تم الترحيل، لكن تعذرت معاينة المستند: $error');
      }
    }
    if (mounted) {
      _amountController.clear();
      _descriptionController.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_canView) {
      return const Center(child: Text('لا تملك صلاحية عرض الحسابات العامة.'));
    }
    if (_isLoading) return const Center(child: CircularProgressIndicator());

    final selectedOwner = _selectedOwner;
    final available = _availableBalanceMinor;
    final noOwners = _owners.isEmpty;
    final noCashAccounts = _cashAccounts.isEmpty;

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: SingleChildScrollView(
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'سداد مستحقات المالك',
                    style: TextStyle(fontSize: 25, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'يسجل سند صرف مرحّلًا على حساب التزامات المالك مقابل الصندوق أو البنك. المتاح هو الرصيد الدائن الفعلي في القيود المرحلة فقط؛ لا تُحتسب إيجارات أو عمولات تلقائيًا. هذه العملية تسجل المستند داخل النظام ولا تنفذ تحويلًا بنكيًا.',
                  ),
                  const SizedBox(height: 18),
                  if (_error != null) ...[
                    _InfoBanner(message: _error!, isError: true),
                    const SizedBox(height: 12),
                  ],
                  if (!_canPost) ...[
                    const _InfoBanner(
                      message:
                          'لديك صلاحية العرض فقط؛ يلزم منح صلاحية ترحيل المحاسبة لإنشاء سند سداد.',
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (noOwners) ...[
                    const _InfoBanner(
                      message:
                          'لا يوجد مالك مرتبط بحساب التزامات تفصيلي صالح تحت 2101. راجع ربط الحسابات قبل السداد.',
                      isError: true,
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (noCashAccounts) ...[
                    const _InfoBanner(
                      message:
                          'لا يوجد حساب صندوق أو بنك تفصيلي صالح برمز يبدأ بـ 11.',
                      isError: true,
                    ),
                    const SizedBox(height: 12),
                  ],
                  DropdownButtonFormField<int>(
                    key: ValueKey(_selectedOwnerId),
                    initialValue: _selectedOwnerId,
                    decoration: const InputDecoration(
                      labelText: 'المالك',
                      border: OutlineInputBorder(),
                    ),
                    items: _owners
                        .map(
                          (owner) => DropdownMenuItem<int>(
                            value: (owner['id'] as num).toInt(),
                            child: Text(
                              '${owner['name']} — ${owner['owner_account_code']}',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: !_canPost || noOwners
                        ? null
                        : (id) {
                            setState(() {
                              _selectedOwnerId = id;
                              _availableBalanceMinor = null;
                            });
                            _loadOwnerBalance(id);
                          },
                    validator: (value) => value == null ? 'اختر المالك' : null,
                  ),
                  const SizedBox(height: 14),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        children: [
                          const Icon(Icons.account_balance_wallet_outlined),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              selectedOwner == null
                                  ? 'اختر مالكًا لعرض الرصيد الدائن الحالي'
                                  : available == null
                                  ? 'جارٍ التحقق من الرصيد المرحّل...'
                                  : 'الرصيد الدائن الحالي — ${selectedOwner['name']}: ${_formatMinor(available)}',
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: 'تحديث الرصيد',
                            onPressed: selectedOwner == null
                                ? null
                                : () => _loadOwnerBalance(_selectedOwnerId),
                            icon: const Icon(Icons.refresh),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  DropdownButtonFormField<int>(
                    key: ValueKey('cash-$_selectedCashAccountId'),
                    initialValue: _selectedCashAccountId,
                    decoration: const InputDecoration(
                      labelText: 'حساب الصندوق أو البنك',
                      border: OutlineInputBorder(),
                    ),
                    items: _cashAccounts
                        .map(
                          (account) => DropdownMenuItem<int>(
                            value: (account['id'] as num).toInt(),
                            child: Text(
                              '${account['code']} — ${account['name']}',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: !_canPost || noCashAccounts
                        ? null
                        : (id) => setState(() => _selectedCashAccountId = id),
                    validator: (value) =>
                        value == null ? 'اختر حساب الصندوق أو البنك' : null,
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: _dateController,
                          readOnly: true,
                          decoration: const InputDecoration(
                            labelText: 'تاريخ السند',
                            border: OutlineInputBorder(),
                            suffixIcon: Icon(Icons.calendar_month),
                          ),
                          onTap: !_canPost ? null : _pickDate,
                          validator: (value) =>
                              DateTime.tryParse(value ?? '') == null
                              ? 'اختر تاريخًا صحيحًا'
                              : null,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: TextFormField(
                          controller: _amountController,
                          enabled: _canPost,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: const InputDecoration(
                            labelText: 'مبلغ السداد',
                            border: OutlineInputBorder(),
                            suffixText: 'بحد أقصى منزلتان عشريتان',
                          ),
                          validator: (value) {
                            final minor = _parseAmountMinor(value ?? '');
                            if (minor == null || minor <= 0) {
                              return 'أدخل مبلغًا موجبًا بدقة لا تتجاوز هللتين';
                            }
                            return null;
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _descriptionController,
                    enabled: _canPost,
                    minLines: 2,
                    maxLines: 4,
                    maxLength: 1000,
                    decoration: const InputDecoration(
                      labelText: 'البيان / سبب السداد',
                      border: OutlineInputBorder(),
                      alignLabelWithHint: true,
                    ),
                    validator: (value) => (value?.trim().isEmpty ?? true)
                        ? 'بيان السداد مطلوب'
                        : null,
                  ),
                  const SizedBox(height: 16),
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: FilledButton.icon(
                      onPressed:
                          !_canPost || _isSaving || noOwners || noCashAccounts
                          ? null
                          : _postSettlement,
                      icon: _isSaving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.receipt_long),
                      label: Text(
                        _isSaving ? 'جارٍ الترحيل...' : 'ترحيل ومعاينة سند PDF',
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (!_canPrint)
                    Text(
                      'يمكن عرض المستند بعد الترحيل، لكن حفظه أو طباعته يتطلب صلاحية الطباعة في المحاسبة.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _InfoBanner extends StatelessWidget {
  const _InfoBanner({required this.message, this.isError = false});

  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final color = isError ? Theme.of(context).colorScheme.error : null;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isError
            ? Theme.of(context).colorScheme.errorContainer
            : Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: color?.withValues(alpha: 0.25) ?? Colors.transparent,
        ),
      ),
      child: Text(message),
    );
  }
}
