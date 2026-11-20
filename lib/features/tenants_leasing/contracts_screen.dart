import '../../core/pdf_preview_dialog.dart';
import '../../core/lease_contract_pdf.dart';
import '../../core/contract_party_snapshot.dart';
import '../../core/contract_term.dart';
import '../../core/rent_period.dart';
import '../../core/permission_policy.dart';
import 'package:flutter/material.dart';
import '../../core/app_theme.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../../providers/leasing_provider.dart';
import '../../providers/property_provider.dart';
import '../../database/database_helper.dart';

class ContractsScreen extends StatefulWidget {
  const ContractsScreen({super.key});

  @override
  State<ContractsScreen> createState() => _ContractsScreenState();
}

class _ContractsScreenState extends State<ContractsScreen> {
  final _formKey = GlobalKey<FormState>();

  int? _selectedTenantId;
  int? _selectedUnitId;
  int? _renewalSourceContractId;
  Map<String, dynamic>? _renewalUnit;
  bool _isSavingContract = false;

  final _startDateController = TextEditingController(
    text: DateFormat('yyyy-MM-dd').format(DateTime.now()),
  );
  final _endDateController = TextEditingController(
    text: DateFormat(
      'yyyy-MM-dd',
    ).format(ContractTerm.endDateForMonths(DateTime.now(), 12)),
  );
  final _totalRentController = TextEditingController();
  final _purposeController = TextEditingController();
  final _electricityReadingController = TextEditingController();

  String _paymentMethod = 'شهري';

  Map<String, dynamic>? _selectedVacantUnit() {
    if (_selectedUnitId == null) return null;
    if (_renewalUnit?['id'] == _selectedUnitId) return _renewalUnit;
    final units = Provider.of<LeasingProvider>(
      context,
      listen: false,
    ).vacantUnits;
    for (final unit in units) {
      if (unit['id'] == _selectedUnitId) return unit;
    }
    return null;
  }

  int? _draftDurationMonths() {
    final startDate = DateTime.tryParse(_startDateController.text);
    final endDate = DateTime.tryParse(_endDateController.text);
    if (startDate == null || endDate == null) return null;
    return ContractTerm.wholeMonths(startDate, endDate);
  }

  // Custom structure to hold manual edit controllers for each installment
  List<Map<String, dynamic>> _generatedInstallments = [];
  List<TextEditingController> _instAmountControllers = [];
  List<TextEditingController> _instDateControllers = [];

  void _disposeInstallmentControllers() {
    for (var c in _instAmountControllers) {
      c.dispose();
    }
    for (var c in _instDateControllers) {
      c.dispose();
    }
    _instAmountControllers.clear();
    _instDateControllers.clear();
  }

  @override
  void dispose() {
    _startDateController.dispose();
    _endDateController.dispose();
    _totalRentController.dispose();
    _purposeController.dispose();
    _electricityReadingController.dispose();
    _disposeInstallmentControllers();
    super.dispose();
  }

  void _addManualInstallment() {
    setState(() {
      _generatedInstallments.add({
        'amount': 0.0,
        'paid_amount': 0.0,
        'due_date': _startDateController.text,
        'status': 'Unpaid',
      });
      _instAmountControllers.add(TextEditingController(text: '0.0'));
      _instDateControllers.add(
        TextEditingController(text: _startDateController.text),
      );
    });
  }

  void _removeManualInstallment(int index) {
    setState(() {
      _generatedInstallments.removeAt(index);
      _instAmountControllers[index].dispose();
      _instDateControllers[index].dispose();
      _instAmountControllers.removeAt(index);
      _instDateControllers.removeAt(index);
    });
  }

  Future<void> _pickContractDate(bool start) async {
    final controller = start ? _startDateController : _endDateController;
    final currentDuration = start ? (_draftDurationMonths() ?? 12) : null;
    final current = DateTime.tryParse(controller.text) ?? DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked == null || !mounted) return;
    setState(() {
      controller.text = DateFormat('yyyy-MM-dd').format(picked);
      if (start) {
        _endDateController.text = DateFormat(
          'yyyy-MM-dd',
        ).format(ContractTerm.endDateForMonths(picked, currentDuration!));
      }
    });
  }

  Future<void> _pickInstallmentDate(int index) async {
    final start =
        DateTime.tryParse(_startDateController.text) ?? DateTime(2000);
    final end = DateTime.tryParse(_endDateController.text) ?? DateTime(2100);
    final current =
        DateTime.tryParse(_instDateControllers[index].text) ?? start;
    final picked = await showDatePicker(
      context: context,
      initialDate: current.isBefore(start)
          ? start
          : current.isAfter(end)
          ? end
          : current,
      firstDate: start,
      lastDate: end.isBefore(start) ? start : end,
    );
    if (picked != null && mounted) {
      setState(() {
        final value = DateFormat('yyyy-MM-dd').format(picked);
        _instDateControllers[index].text = value;
        _generatedInstallments[index]['due_date'] = value;
      });
    }
  }

  Future<void> _beginRenewal(Map<String, dynamic> contract) async {
    if (!PermissionRuntime.allows('leasing', AppPermissionAction.add)) return;
    if (contract['status'] != 'Active' ||
        contract['renewed_to_contract_id'] != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('هذا العقد غير متاح للتجديد')),
      );
      return;
    }
    final contractId = (contract['id'] as num?)?.toInt();
    final unitId = (contract['unit_id'] as num?)?.toInt();
    final tenantId = (contract['tenant_id'] as num?)?.toInt();
    final previousEnd = DateTime.tryParse(
      contract['end_date']?.toString() ?? '',
    );
    if (contractId == null ||
        unitId == null ||
        tenantId == null ||
        previousEnd == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('بيانات العقد السابق غير مكتملة')),
      );
      return;
    }

    try {
      final db = await DatabaseHelper.instance.database;
      final unitRows = await db.query(
        'units',
        where: 'id = ?',
        whereArgs: [unitId],
        limit: 1,
      );
      if (unitRows.isEmpty)
        throw StateError('الوحدة المرتبطة بالعقد غير موجودة');
      final nextStart = DateTime(
        previousEnd.year,
        previousEnd.month,
        previousEnd.day,
      ).add(const Duration(days: 1));
      final previousStart =
          DateTime.tryParse(contract['start_date']?.toString() ?? '') ??
          previousEnd;
      final durationMonths =
          ContractTerm.wholeMonths(previousStart, previousEnd) ?? 12;
      final nextEnd = ContractTerm.endDateForMonths(nextStart, durationMonths);
      if (!mounted) return;

      _disposeInstallmentControllers();
      setState(() {
        _renewalSourceContractId = contractId;
        _renewalUnit = Map<String, dynamic>.from(unitRows.first);
        _selectedTenantId = tenantId;
        _selectedUnitId = unitId;
        _startDateController.text = DateFormat('yyyy-MM-dd').format(nextStart);
        _endDateController.text = DateFormat('yyyy-MM-dd').format(nextEnd);
        final previousRent = contract['rent_amount'] as num?;
        _totalRentController.text = previousRent == null
            ? ''
            : previousRent.toStringAsFixed(2);
        final previousPaymentMethod = contract['payment_method']?.toString();
        _paymentMethod =
            const [
              'شهري',
              'ربع سنوي',
              'نصف سنوي',
              'سنوي',
              'دفعة واحدة',
            ].contains(previousPaymentMethod)
            ? previousPaymentMethod!
            : 'شهري';
        _purposeController.text = contract['purpose']?.toString() ?? '';
        _electricityReadingController.text =
            contract['electricity_reading']?.toString() ?? '';
        _generatedInstallments.clear();
      });
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('تعذر تجهيز التجديد: $error')));
      }
    }
  }

  void _clearDraft() {
    _disposeInstallmentControllers();
    _selectedTenantId = null;
    _selectedUnitId = null;
    _renewalSourceContractId = null;
    _renewalUnit = null;
    _totalRentController.clear();
    _purposeController.clear();
    _electricityReadingController.clear();
    _generatedInstallments.clear();
    _paymentMethod = 'شهري';
    final today = DateTime.now();
    _startDateController.text = DateFormat('yyyy-MM-dd').format(today);
    _endDateController.text = DateFormat(
      'yyyy-MM-dd',
    ).format(ContractTerm.endDateForMonths(today, 12));
  }

  void _generateInstallments() {
    final unit = _selectedVacantUnit();
    if (unit == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('اختر الوحدة أولاً')));
      return;
    }
    if (!RentPeriod.isValid(unit['default_rent_period'])) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('حدد دورية إيجار الوحدة من بيانات العقار أولاً'),
        ),
      );
      return;
    }
    final totalRent = double.tryParse(_totalRentController.text) ?? 0.0;
    if (!totalRent.isFinite ||
        totalRent <= 0 ||
        (totalRent * 100 - (totalRent * 100).round()).abs() > 0.000001) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('أدخل إجماليًا موجبًا بدقة منزلتين عشريتين'),
        ),
      );
      return;
    }

    final startDate = DateTime.tryParse(_startDateController.text);
    final endDate = DateTime.tryParse(_endDateController.text);
    if (startDate == null || endDate == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تاريخ بداية أو نهاية العقد غير صحيح')),
      );
      return;
    }
    final durationMonths = ContractTerm.wholeMonths(startDate, endDate);
    if (durationMonths == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'مدة العقد يجب أن تكون شهرًا أو عددًا صحيحًا من الشهور؛ لا تُحسب أيام جزئية.',
          ),
        ),
      );
      return;
    }

    late final List<int> weights;
    late final List<int> amountsMinor;
    try {
      weights = ContractTerm.paymentMonthWeights(
        durationMonths,
        _paymentMethod,
      );
      amountsMinor = ContractTerm.allocateMinorUnits(
        (totalRent * 100).round(),
        weights,
      );
    } on ArgumentError catch (error) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$error')));
      return;
    }

    List<Map<String, dynamic>> newInstallments = [];
    _disposeInstallmentControllers(); // Clear old controllers

    var elapsedMonths = 0;
    for (var i = 0; i < weights.length; i++) {
      final dueDate = ContractTerm.addMonthsClamped(startDate, elapsedMonths);
      final currentAmount = amountsMinor[i] / 100.0;

      String dateStr = DateFormat('yyyy-MM-dd').format(dueDate);

      newInstallments.add({
        'amount': currentAmount,
        'paid_amount': 0.0,
        'due_date': dateStr,
        'status': 'Unpaid',
      });

      _instAmountControllers.add(
        TextEditingController(text: currentAmount.toString()),
      );
      _instDateControllers.add(TextEditingController(text: dateStr));
      elapsedMonths += weights[i];
    }

    setState(() {
      _generatedInstallments = newInstallments;
    });
  }

  void _saveContract() async {
    if (_isSavingContract) return;
    if (_formKey.currentState!.validate() &&
        _selectedTenantId != null &&
        _selectedUnitId != null) {
      if (_generatedInstallments.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('الرجاء توليد الأقساط أولاً')),
        );
        return;
      }

      final selectedUnit = _selectedVacantUnit();
      if (selectedUnit == null ||
          !RentPeriod.isValid(selectedUnit['default_rent_period'])) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('حدد دورية إيجار الوحدة قبل حفظ العقد')),
        );
        return;
      }

      final totalRent = double.tryParse(_totalRentController.text) ?? 0.0;
      final startDate = DateTime.tryParse(_startDateController.text);
      final endDate = DateTime.tryParse(_endDateController.text);
      final sumInstallments = _generatedInstallments.fold<double>(
        0,
        (sum, item) => sum + ((item['amount'] as num?)?.toDouble() ?? 0),
      );
      final amountsValid =
          totalRent.isFinite &&
          totalRent > 0 &&
          sumInstallments.isFinite &&
          _generatedInstallments.every((item) {
            final amount = (item['amount'] as num?)?.toDouble() ?? 0;
            return amount.isFinite && amount > 0;
          });
      if (!amountsValid) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'إجمالي العقد وكل قسط يجب أن يكونا مبالغ موجبة وصالحة',
            ),
          ),
        );
        return;
      }
      final datesValid =
          startDate != null &&
          endDate != null &&
          !startDate.isAfter(endDate) &&
          ContractTerm.wholeMonths(startDate, endDate) != null &&
          _generatedInstallments.every((item) {
            final due = DateTime.tryParse(item['due_date']?.toString() ?? '');
            return (item['amount'] as num? ?? 0) > 0 &&
                due != null &&
                !due.isBefore(startDate) &&
                !due.isAfter(endDate);
          });

      if (!datesValid) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'تحقق من أن مدة العقد شهور كاملة ومن تواريخ الأقساط ومبالغها',
            ),
          ),
        );
        return;
      }
      if ((totalRent * 100).round() != (sumInstallments * 100).round()) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'إجمالي مبلغ الأقساط (${sumInstallments.toStringAsFixed(2)}) لا يتطابق مع القيمة الإجمالية للعقد (${totalRent.toStringAsFixed(2)})',
            ),
          ),
        );
        return;
      }

      final contract = {
        'tenant_id': _selectedTenantId,
        'unit_id': _selectedUnitId,
        'start_date': _startDateController.text,
        'end_date': _endDateController.text,
        'rent_amount': double.tryParse(_totalRentController.text) ?? 0.0,
        'payment_method': _paymentMethod,
        'purpose': _purposeController.text.trim(),
        'electricity_reading': _electricityReadingController.text.trim(),
        'status': 'Active',
      };

      setState(() => _isSavingContract = true);
      try {
        final provider = Provider.of<LeasingProvider>(context, listen: false);
        final contractId = _renewalSourceContractId == null
            ? await provider.addContract(contract, _generatedInstallments)
            : await provider.renewContract(
                _renewalSourceContractId!,
                contract,
                _generatedInstallments,
              );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                _renewalSourceContractId == null
                    ? 'تم حفظ العقد رقم $contractId وتحديث حالة الوحدة'
                    : 'تم إنشاء عقد التجديد رقم $contractId؛ بقيت الذمم والأقساط السابقة على العقد السابق',
              ),
            ),
          );
          setState(() {
            _clearDraft();
          });
        }
      } catch (e) {
        if (mounted)
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('خطأ: $e')));
      } finally {
        if (mounted) setState(() => _isSavingContract = false);
      }
    } else {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('الرجاء تعبئة جميع الحقول')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer2<LeasingProvider, PropertyProvider>(
      builder: (context, leasingProv, propProv, child) {
        if (leasingProv.isLoading || propProv.isLoading) {
          return const Center(child: CircularProgressIndicator());
        }
        if (propProv.errorMessage != null) {
          return Center(child: Text(propProv.errorMessage!));
        }

        final selectedUnit = _selectedVacantUnit();
        final formUnits = List<Map<String, dynamic>>.from(
          leasingProv.vacantUnits,
        );
        if (_renewalUnit != null &&
            !formUnits.any((unit) => unit['id'] == _renewalUnit!['id'])) {
          formUnits.add(_renewalUnit!);
        }
        final durationMonths = _draftDurationMonths();

        return Padding(
          padding: const EdgeInsets.all(24.0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Left side: Contract Form
              Expanded(
                flex: 1,
                child: SingleChildScrollView(
                  child: Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          _renewalSourceContractId == null
                              ? 'إنشاء عقد جديد'
                              : 'تجديد العقد رقم $_renewalSourceContractId',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        if (_renewalSourceContractId != null) ...[
                          const SizedBox(height: 8),
                          Card(
                            color: AppPalette.navy.withValues(alpha: 0.06),
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Row(
                                children: [
                                  const Icon(
                                    Icons.info_outline,
                                    color: AppPalette.navy,
                                  ),
                                  const SizedBox(width: 8),
                                  const Expanded(
                                    child: Text(
                                      'سيُنشأ عقد جديد مرتبط بالسابق. لن تتغير الأقساط أو الفواتير أو القيود والذمم القديمة؛ أدخل الإجمالي الجديد المتفق عليه.',
                                    ),
                                  ),
                                  TextButton.icon(
                                    onPressed: () => setState(_clearDraft),
                                    icon: const Icon(Icons.close),
                                    label: const Text('إلغاء التجديد'),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                        const SizedBox(height: 16),
                        DropdownButtonFormField<int>(
                          value: _selectedTenantId,
                          items: leasingProv.tenants
                              .map(
                                (t) => DropdownMenuItem<int>(
                                  value: t['id'],
                                  child: Text(t['name']),
                                ),
                              )
                              .toList(),
                          onChanged: _renewalSourceContractId == null
                              ? (val) => setState(() => _selectedTenantId = val)
                              : null,
                          decoration: const InputDecoration(
                            labelText: 'المستأجر',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 16),
                        DropdownButtonFormField<int>(
                          value: _selectedUnitId,
                          isExpanded: true,
                          items: formUnits.map((u) {
                            final propName = propProv.properties.firstWhere(
                              (p) => p['id'] == u['property_id'],
                              orElse: () => {'name': ''},
                            )['name'];
                            final rentPeriod = RentPeriod.label(
                              u['default_rent_period'],
                            );
                            final rentDetails = rentPeriod == null
                                ? ' — دورية غير محددة'
                                : u['default_rent'] == null
                                ? ' — السعر غير محدد ($rentPeriod)'
                                : ' — ${u['default_rent']} $rentPeriod';
                            return DropdownMenuItem<int>(
                              value: u['id'],
                              child: Text(
                                'عقار: $propName - وحدة: ${u['unit_number']}$rentDetails',
                                overflow: TextOverflow.ellipsis,
                              ),
                            );
                          }).toList(),
                          onChanged: _renewalSourceContractId == null
                              ? (val) {
                                  _disposeInstallmentControllers();
                                  setState(() {
                                    _selectedUnitId = val;
                                    _renewalUnit = null;
                                    _totalRentController.clear();
                                    _generatedInstallments.clear();
                                  });
                                }
                              : null,
                          decoration: InputDecoration(
                            labelText: _renewalSourceContractId == null
                                ? 'الوحدة الشاغرة'
                                : 'الوحدة المرتبطة بالعقد السابق',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        if (selectedUnit != null) ...[
                          const SizedBox(height: 8),
                          Card(
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Icon(
                                    RentPeriod.isValid(
                                          selectedUnit['default_rent_period'],
                                        )
                                        ? Icons.price_change_outlined
                                        : Icons.warning_amber_outlined,
                                    color:
                                        RentPeriod.isValid(
                                          selectedUnit['default_rent_period'],
                                        )
                                        ? AppPalette.navy
                                        : Colors.deepOrange,
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        const Text(
                                          'سعر الوحدة المرجعي',
                                          style: TextStyle(
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                        Text(
                                          !RentPeriod.isValid(
                                                selectedUnit['default_rent_period'],
                                              )
                                              ? 'الدورية غير محددة؛ عدّل بيانات الوحدة قبل إنشاء العقد.'
                                              : selectedUnit['default_rent'] ==
                                                    null
                                              ? 'لا يوجد سعر افتراضي؛ أدخل إجمالي العقد المتفق عليه.'
                                              : '${selectedUnit['default_rent']} ريال ${RentPeriod.label(selectedUnit['default_rent_period'])}',
                                        ),
                                        const Text(
                                          'أدخل إجمالي العقد المتفق عليه صراحةً؛ سعر الوحدة الدوري ليس إجمالي العقد تلقائيًا.',
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(
                              child: TextFormField(
                                controller: _startDateController,
                                decoration: InputDecoration(
                                  labelText: _renewalSourceContractId == null
                                      ? 'بداية العقد'
                                      : 'بداية التجديد',
                                  border: OutlineInputBorder(),
                                ),
                                readOnly: true,
                                onTap: _renewalSourceContractId == null
                                    ? () => _pickContractDate(true)
                                    : null,
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: TextFormField(
                                controller: _endDateController,
                                decoration: const InputDecoration(
                                  labelText: 'نهاية العقد',
                                  border: OutlineInputBorder(),
                                ),
                                readOnly: true,
                                onTap: () => _pickContractDate(false),
                              ),
                            ),
                          ],
                        ),
                        Padding(
                          padding: const EdgeInsetsDirectional.only(top: 8),
                          child: Text(
                            durationMonths == null
                                ? 'يجب أن تمثل البداية والنهاية مدة شهرية كاملة؛ لا تُحتسب أيام جزئية.'
                                : 'مدة العقد: $durationMonths شهرًا كاملة، دون احتساب يومي.',
                            style: TextStyle(
                              color: durationMonths == null
                                  ? Colors.deepOrange
                                  : AppPalette.navy,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _totalRentController,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: InputDecoration(
                            labelText: _renewalSourceContractId == null
                                ? 'إجمالي قيمة العقد المتفق عليها'
                                : 'إجمالي قيمة التجديد المتفق عليها',
                            border: OutlineInputBorder(),
                          ),
                          validator: (v) {
                            final value = double.tryParse(v ?? '');
                            return value == null ||
                                    !value.isFinite ||
                                    value <= 0
                                ? 'أدخل قيمة عقد موجبة'
                                : null;
                          },
                        ),
                        const SizedBox(height: 16),
                        DropdownButtonFormField<String>(
                          value: _paymentMethod,
                          items:
                              [
                                    'شهري',
                                    'ربع سنوي',
                                    'نصف سنوي',
                                    'سنوي',
                                    'دفعة واحدة',
                                  ]
                                  .map(
                                    (m) => DropdownMenuItem(
                                      value: m,
                                      child: Text(m),
                                    ),
                                  )
                                  .toList(),
                          onChanged: (val) =>
                              setState(() => _paymentMethod = val!),
                          decoration: const InputDecoration(
                            labelText: 'طريقة الدفع',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _purposeController,
                          decoration: const InputDecoration(
                            labelText: 'الغرض من الاستئجار (مثال: سكني)',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _electricityReadingController,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'قراءة عداد الكهرباء عند بدء الإيجار',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 24),
                        ElevatedButton(
                          onPressed:
                              PermissionRuntime.allows(
                                'leasing',
                                AppPermissionAction.add,
                              )
                              ? _generateInstallments
                              : null,
                          child: const Text('توليد جدول الأقساط'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 24),
              // Right side: Generated Installments & Save
              Expanded(
                flex: 1,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'جدول الدفعات (الأقساط)',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        if (_generatedInstallments.isNotEmpty)
                          IconButton(
                            icon: const Icon(
                              Icons.add_circle,
                              color: AppPalette.navy,
                            ),
                            tooltip: 'إضافة دفعة جديدة يدوياً',
                            onPressed:
                                PermissionRuntime.allows(
                                  'leasing',
                                  AppPermissionAction.add,
                                )
                                ? _addManualInstallment
                                : null,
                          ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.grey.shade300),
                        ),
                        child: _generatedInstallments.isEmpty
                            ? const Center(
                                child: Text('لم يتم توليد الأقساط بعد'),
                              )
                            : ListView.builder(
                                itemCount: _generatedInstallments.length,
                                itemBuilder: (context, index) {
                                  return Card(
                                    margin: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 4,
                                    ),
                                    child: Padding(
                                      padding: const EdgeInsets.all(8.0),
                                      child: Row(
                                        children: [
                                          CircleAvatar(
                                            child: Text('${index + 1}'),
                                          ),
                                          const SizedBox(width: 16),
                                          Expanded(
                                            child: TextFormField(
                                              controller:
                                                  _instDateControllers[index],
                                              decoration: const InputDecoration(
                                                labelText: 'تاريخ الاستحقاق',
                                                isDense: true,
                                              ),
                                              readOnly: true,
                                              onTap: () =>
                                                  _pickInstallmentDate(index),
                                            ),
                                          ),
                                          const SizedBox(width: 16),
                                          Expanded(
                                            child: TextFormField(
                                              controller:
                                                  _instAmountControllers[index],
                                              keyboardType:
                                                  TextInputType.number,
                                              decoration: const InputDecoration(
                                                labelText: 'المبلغ',
                                                isDense: true,
                                              ),
                                              onChanged: (val) =>
                                                  _generatedInstallments[index]['amount'] =
                                                      double.tryParse(val) ??
                                                      0.0,
                                            ),
                                          ),
                                          IconButton(
                                            icon: const Icon(
                                              Icons.remove_circle,
                                              color: Colors.red,
                                            ),
                                            tooltip: 'حذف',
                                            onPressed:
                                                PermissionRuntime.allows(
                                                  'leasing',
                                                  AppPermissionAction.add,
                                                )
                                                ? () =>
                                                      _removeManualInstallment(
                                                        index,
                                                      )
                                                : null,
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed:
                          _generatedInstallments.isNotEmpty &&
                              !_isSavingContract &&
                              PermissionRuntime.allows(
                                'leasing',
                                AppPermissionAction.add,
                              )
                          ? _saveContract
                          : null,
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.all(16),
                        backgroundColor: Colors.green,
                      ),
                      child: Text(
                        _renewalSourceContractId == null
                            ? 'حفظ العقد واعتماد الأقساط'
                            : 'حفظ عقد التجديد واعتماد أقساطه',
                        style: const TextStyle(fontSize: 18),
                      ),
                    ),
                    const SizedBox(height: 32),
                    const Divider(),
                    const Text(
                      'إدارة العقود الحالية',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Expanded(
                      child: ListView.builder(
                        itemCount: leasingProv.contracts.length,
                        itemBuilder: (context, index) {
                          final contract = leasingProv.contracts[index];
                          final tenantName =
                              ContractPartySnapshot.tenantName(contract) ??
                              leasingProv.tenants.firstWhere(
                                (t) => t['id'] == contract['tenant_id'],
                                orElse: () => {'name': 'غير معروف'},
                              )['name'];
                          final renewedToContractId =
                              contract['renewed_to_contract_id'];
                          final renewedFromContractId =
                              contract['renewed_from_contract_id'];
                          final statusLabel = renewedToContractId == null
                              ? '${contract['status']}'
                              : 'مجدّد إلى العقد $renewedToContractId';
                          return Card(
                            child: InkWell(
                              onTap: () => _showContractDetailsDialog(
                                contract,
                                tenantName,
                              ),
                              child: ListTile(
                                title: Text(
                                  'عقد رقم: ${contract['id']} - المستأجر: $tenantName',
                                ),
                                subtitle: Text(
                                  'الحالة: $statusLabel'
                                  '${renewedFromContractId == null ? '' : ' | تجديد للعقد $renewedFromContractId'}'
                                  ' | الإجمالي: ${contract['rent_amount']}',
                                ),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      icon: const Icon(
                                        Icons.print,
                                        color: AppPalette.navy,
                                      ),
                                      tooltip: 'طباعة العقد (PDF)',
                                      onPressed:
                                          PermissionRuntime.allows(
                                            'leasing',
                                            AppPermissionAction.print,
                                          )
                                          ? () => _printContract(
                                              contract,
                                              saveAsPdf: false,
                                            )
                                          : null,
                                    ),
                                    IconButton(
                                      icon: const Icon(
                                        Icons.picture_as_pdf,
                                        color: Colors.deepOrange,
                                      ),
                                      tooltip: 'حفظ العقد PDF',
                                      onPressed:
                                          PermissionRuntime.allows(
                                            'leasing',
                                            AppPermissionAction.print,
                                          )
                                          ? () => _printContract(
                                              contract,
                                              saveAsPdf: true,
                                            )
                                          : null,
                                    ),
                                    if (contract['status'] == 'Active' &&
                                        renewedToContractId == null)
                                      IconButton(
                                        icon: const Icon(
                                          Icons.autorenew,
                                          color: AppPalette.navy,
                                        ),
                                        tooltip: 'تجديد العقد بشروط جديدة',
                                        onPressed:
                                            PermissionRuntime.allows(
                                              'leasing',
                                              AppPermissionAction.add,
                                            )
                                            ? () => _beginRenewal(contract)
                                            : null,
                                      ),
                                    if (contract['status'] == 'Active' &&
                                        renewedToContractId == null)
                                      IconButton(
                                        icon: const Icon(
                                          Icons.cancel,
                                          color: Colors.red,
                                        ),
                                        tooltip: 'إلغاء العقد',
                                        onPressed:
                                            PermissionRuntime.allows(
                                              'leasing',
                                              AppPermissionAction.edit,
                                            )
                                            ? () => _cancelContract(
                                                contract['id'],
                                              )
                                            : null,
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showContractDetailsDialog(
    Map<String, dynamic> contract,
    String tenantName,
  ) async {
    final db = await DatabaseHelper.instance.database;
    final installments = await db.query(
      'contract_installments',
      where: 'contract_id = ?',
      whereArgs: [contract['id']],
    );

    if (!mounted) return;

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('تفاصيل العقد رقم: ${contract['id']}'),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'المستأجر: $tenantName',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                Text(
                  'المدة: من ${contract['start_date']} إلى ${contract['end_date']}',
                ),
                if (contract['renewed_from_contract_id'] != null)
                  Text(
                    'هذا العقد تجديد للعقد رقم ${contract['renewed_from_contract_id']}',
                  ),
                if (contract['renewed_to_contract_id'] != null)
                  Text(
                    'تم تجديد هذا العقد بالعقد رقم ${contract['renewed_to_contract_id']}',
                  ),
                Text('طريقة الدفع: ${contract['payment_method']}'),
                Text('الإجمالي: ${contract['rent_amount']} ريال'),
                if (contract['status'] == 'Cancelled') ...[
                  Text(
                    'سبب الإلغاء: ${contract['cancellation_reason']?.toString().trim().isNotEmpty == true ? contract['cancellation_reason'] : 'غير موثق في النظام'}',
                  ),
                  if (contract['cancelled_at']?.toString().isNotEmpty == true)
                    Text('تاريخ الإلغاء: ${contract['cancelled_at']}'),
                ],
                const Divider(),
                const Text(
                  'الأقساط:',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: installments.length,
                    itemBuilder: (context, idx) {
                      final inst = installments[idx];
                      return ListTile(
                        leading: CircleAvatar(child: Text('${idx + 1}')),
                        title: Text('تاريخ: ${inst['due_date']}'),
                        subtitle: Text(
                          'الحالة: ${inst['status']} | المدفوع: ${inst['paid_amount']}',
                        ),
                        trailing: Text(
                          '${inst['amount']} ريال',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('إغلاق'),
            ),
            ElevatedButton.icon(
              onPressed:
                  PermissionRuntime.allows('leasing', AppPermissionAction.print)
                  ? () {
                      Navigator.pop(context);
                      _printContract(contract, saveAsPdf: false);
                    }
                  : null,
              icon: const Icon(Icons.print),
              label: const Text('طباعة العقد PDF'),
            ),
            OutlinedButton.icon(
              onPressed:
                  PermissionRuntime.allows('leasing', AppPermissionAction.print)
                  ? () {
                      Navigator.pop(context);
                      _printContract(contract, saveAsPdf: true);
                    }
                  : null,
              icon: const Icon(Icons.save_alt),
              label: const Text('حفظ PDF'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _printContract(
    Map<String, dynamic> contract, {
    required bool saveAsPdf,
  }) async {
    try {
      final db = await DatabaseHelper.instance.database;
      final companyInfo = await DatabaseHelper.instance.getCompanyInfo();
      final savedSnapshot = ContractPartySnapshot.decode(contract);
      final savedOwner = ContractPartySnapshot.section(savedSnapshot, 'owner');
      final savedTenant = ContractPartySnapshot.section(
        savedSnapshot,
        'tenant',
      );
      final savedProperty = ContractPartySnapshot.section(
        savedSnapshot,
        'property',
      );
      final savedUnit = ContractPartySnapshot.section(savedSnapshot, 'unit');
      if (savedOwner.isNotEmpty &&
          savedTenant.isNotEmpty &&
          savedProperty.isNotEmpty &&
          savedUnit.isNotEmpty) {
        final savedUnitType = savedSnapshot['unit_type_name']?.toString() ?? '';
        final savedPropertyType =
            savedSnapshot['property_type_name']?.toString() ?? '';
        final bytes = await LeaseContractPdf.build(
          companyInfo: companyInfo,
          contract: contract,
          owner: savedOwner,
          tenant: savedTenant,
          property: savedProperty,
          unit: savedUnit,
          cityName: savedSnapshot['city_name']?.toString() ?? '',
          unitTypeName: savedUnitType.isEmpty
              ? savedPropertyType
              : savedUnitType,
        );
        if (mounted) {
          await PdfDocumentPreviewDialog.show(
            context: context,
            bytes: bytes,
            fileName: 'عقد_إيجار_${contract['id']}',
            preferredIntent: saveAsPdf
                ? PdfPreviewIntent.save
                : PdfPreviewIntent.printDocument,
            permissionModule: 'leasing',
          );
        }
        return;
      }

      final tenantRows = await db.query(
        'tenants',
        where: 'id = ?',
        whereArgs: [contract['tenant_id']],
        limit: 1,
      );
      if (tenantRows.isEmpty) throw StateError('بيانات المستأجر غير متاحة');
      final tenant = Map<String, dynamic>.from(tenantRows.first);
      if (tenant['nationality_id'] != null) {
        final nationalityRows = await db.query(
          'nationalities',
          columns: ['name'],
          where: 'id = ?',
          whereArgs: [tenant['nationality_id']],
          limit: 1,
        );
        tenant['nationality_name'] = nationalityRows.isEmpty
            ? ''
            : nationalityRows.first['name'];
      }

      final unitRows = await db.query(
        'units',
        where: 'id = ?',
        whereArgs: [contract['unit_id']],
        limit: 1,
      );
      if (unitRows.isEmpty) throw StateError('بيانات الوحدة غير متاحة');
      final unit = Map<String, dynamic>.from(unitRows.first);
      final propertyRows = await db.query(
        'properties',
        where: 'id = ?',
        whereArgs: [unit['property_id']],
        limit: 1,
      );
      if (propertyRows.isEmpty) throw StateError('بيانات العقار غير متاحة');
      final property = Map<String, dynamic>.from(propertyRows.first);

      var owner = <String, dynamic>{};
      final ownerRows = await db.query(
        'owners',
        where: 'id = ?',
        whereArgs: [unit['owner_id'] ?? property['owner_id']],
        limit: 1,
      );
      if (ownerRows.isNotEmpty)
        owner = Map<String, dynamic>.from(ownerRows.first);

      var unitTypeName = '';
      if (unit['unit_type_id'] != null) {
        final rows = await db.query(
          'unit_types',
          columns: ['name'],
          where: 'id = ?',
          whereArgs: [unit['unit_type_id']],
          limit: 1,
        );
        if (rows.isNotEmpty)
          unitTypeName = rows.first['name']?.toString() ?? '';
      }
      var propertyTypeName = '';
      if (property['property_type_id'] != null) {
        final rows = await db.query(
          'property_types',
          columns: ['name'],
          where: 'id = ?',
          whereArgs: [property['property_type_id']],
          limit: 1,
        );
        if (rows.isNotEmpty) {
          propertyTypeName = rows.first['name']?.toString() ?? '';
        }
      }
      var cityName = '';
      if (property['city_id'] != null) {
        final rows = await db.query(
          'cities',
          columns: ['name'],
          where: 'id = ?',
          whereArgs: [property['city_id']],
          limit: 1,
        );
        if (rows.isNotEmpty) cityName = rows.first['name']?.toString() ?? '';
      }

      final documentOwner = {
        ...owner,
        ...ContractPartySnapshot.section(savedSnapshot, 'owner'),
      };
      final documentTenant = {
        ...tenant,
        ...ContractPartySnapshot.section(savedSnapshot, 'tenant'),
      };
      final documentProperty = {
        ...property,
        ...ContractPartySnapshot.section(savedSnapshot, 'property'),
      };
      final documentUnit = {
        ...unit,
        ...ContractPartySnapshot.section(savedSnapshot, 'unit'),
      };
      if (savedSnapshot.isNotEmpty) {
        cityName = savedSnapshot['city_name']?.toString() ?? '';
        unitTypeName = savedSnapshot['unit_type_name']?.toString() ?? '';
        propertyTypeName =
            savedSnapshot['property_type_name']?.toString() ?? '';
      }

      final bytes = await LeaseContractPdf.build(
        companyInfo: companyInfo,
        contract: contract,
        owner: documentOwner,
        tenant: documentTenant,
        property: documentProperty,
        unit: documentUnit,
        cityName: cityName,
        unitTypeName: unitTypeName.isEmpty ? propertyTypeName : unitTypeName,
      );
      final name = 'عقد_إيجار_${contract['id']}';
      if (mounted) {
        await PdfDocumentPreviewDialog.show(
          context: context,
          bytes: bytes,
          fileName: name,
          preferredIntent: saveAsPdf
              ? PdfPreviewIntent.save
              : PdfPreviewIntent.printDocument,
          permissionModule: 'leasing',
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تعذر تجهيز/طباعة عقد الإيجار: $e')),
        );
      }
    }
  }

  void _cancelContract(int contractId) async {
    final leasingProvider = Provider.of<LeasingProvider>(
      context,
      listen: false,
    );
    final reasonController = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        var showReasonError = false;
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) => AlertDialog(
            title: const Text('تأكيد إلغاء العقد'),
            content: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'سجّل سبب الإلغاء ليبقى موثقًا في سجل العقد. لن يحذف النظام العقد أو أقساطه. إذا وُجد قبض أو فاتورة فسيُرفض الإلغاء المباشر وتلزم تسوية منفصلة.',
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: reasonController,
                    maxLines: 3,
                    maxLength: 500,
                    decoration: InputDecoration(
                      labelText: 'سبب الإلغاء (مطلوب)',
                      errorText: showReasonError ? 'سبب الإلغاء مطلوب' : null,
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: (_) {
                      if (showReasonError) {
                        setDialogState(() => showReasonError = false);
                      }
                    },
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('تراجع'),
              ),
              ElevatedButton.icon(
                onPressed: () {
                  final normalizedReason = reasonController.text.trim();
                  if (normalizedReason.isEmpty) {
                    setDialogState(() => showReasonError = true);
                    return;
                  }
                  Navigator.pop(dialogContext, normalizedReason);
                },
                icon: const Icon(Icons.cancel),
                style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                label: const Text('حفظ السبب وإلغاء العقد'),
              ),
            ],
          ),
        );
      },
    );
    reasonController.dispose();
    final normalizedReason = reason?.trim();
    if (!mounted || normalizedReason == null || normalizedReason.isEmpty) {
      return;
    }
    try {
      await leasingProvider.cancelContract(
        contractId,
        reason: normalizedReason,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('تم إلغاء العقد بنجاح')));
    } catch (e) {
      if (mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('لا يمكن الإلغاء'),
            content: Text(e.toString()),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('حسناً'),
              ),
            ],
          ),
        );
      }
    }
  }
}
