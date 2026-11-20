import 'dart:convert';

import 'package:flutter/material.dart';

import '../../core/permission_policy.dart';
import '../../database/database_helper.dart';

class PropertySaleReviewsScreen extends StatefulWidget {
  const PropertySaleReviewsScreen({super.key});

  @override
  State<PropertySaleReviewsScreen> createState() =>
      _PropertySaleReviewsScreenState();
}

class _PropertySaleReviewsScreenState extends State<PropertySaleReviewsScreen> {
  List<Map<String, Object?>> _reviews = [];
  final Map<int, Future<List<Map<String, Object?>>>> _eventFutures = {};
  final Set<int> _expandedReviewIds = {};
  bool _isLoading = true;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _loadReviews();
  }

  Future<void> _loadReviews() async {
    setState(() {
      _isLoading = true;
      _loadError = null;
    });
    try {
      final rows = await DatabaseHelper.instance.getPropertySaleReviews();
      if (!mounted) return;
      setState(() {
        _reviews = rows;
        _eventFutures.clear();
        for (final reviewId in _expandedReviewIds) {
          if (rows.any((row) => (row['id'] as num).toInt() == reviewId)) {
            _eventFutures[reviewId] = DatabaseHelper.instance
                .getPropertySaleReviewEvents(reviewId);
          }
        }
        _isLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = error.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _showCreateDialog() async {
    final properties = await DatabaseHelper.instance
        .getPropertySaleProperties();
    final owners = await DatabaseHelper.instance.getPropertySaleOwners();
    if (!mounted) return;
    if (properties.isEmpty) {
      _showMessage('أضف عقارًا أولًا قبل إنشاء طلب مراجعة بيع.');
      return;
    }
    if (owners.isEmpty) {
      _showMessage('أضف مالكًا يمثل المشتري قبل إنشاء طلب مراجعة البيع.');
      return;
    }

    final formKey = GlobalKey<FormState>();
    final reasonController = TextEditingController();
    final amountController = TextEditingController();
    var targetType = 'property';
    var propertyId = (properties.first['id'] as num).toInt();
    int? unitId;
    final firstSellerValue = properties.first['owner_id'];
    final firstSellerId = firstSellerValue is num
        ? firstSellerValue.toInt()
        : null;
    final firstBuyer = owners.firstWhere(
      (owner) => (owner['id'] as num).toInt() != firstSellerId,
      orElse: () => owners.first,
    );
    var buyerOwnerId = (firstBuyer['id'] as num).toInt();
    var proposedSaleDate = _toIsoDate(DateTime.now());
    var units = await DatabaseHelper.instance.getPropertySaleUnits(propertyId);
    if (!mounted) {
      reasonController.dispose();
      amountController.dispose();
      return;
    }
    var isDialogSaving = false;

    int? selectedSellerOwnerId() {
      if (targetType == 'unit' && unitId != null) {
        final selectedUnit = units.firstWhere(
          (unit) => (unit['id'] as num).toInt() == unitId,
          orElse: () => const <String, Object?>{},
        );
        final ownerId = selectedUnit['effective_owner_id'];
        return ownerId is num ? ownerId.toInt() : null;
      }
      final selectedProperty = properties.firstWhere(
        (property) => (property['id'] as num).toInt() == propertyId,
        orElse: () => const <String, Object?>{},
      );
      final ownerId = selectedProperty['owner_id'];
      return ownerId is num ? ownerId.toInt() : null;
    }

    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => StatefulBuilder(
          builder: (dialogContext, setDialogState) => PopScope(
            canPop: !isDialogSaving,
            child: AlertDialog(
              title: const Text('طلب مراجعة بيع'),
              content: SizedBox(
                width: 620,
                child: Form(
                  key: formKey,
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        DropdownButtonFormField<String>(
                          initialValue: targetType,
                          decoration: const InputDecoration(
                            labelText: 'نطاق الطلب',
                            border: OutlineInputBorder(),
                          ),
                          items: const [
                            DropdownMenuItem(
                              value: 'property',
                              child: Text('العقار كاملًا'),
                            ),
                            DropdownMenuItem(
                              value: 'unit',
                              child: Text('وحدة محددة'),
                            ),
                          ],
                          onChanged: isDialogSaving
                              ? null
                              : (value) {
                                  if (value == null) return;
                                  setDialogState(() {
                                    targetType = value;
                                    unitId = null;
                                  });
                                },
                        ),
                        const SizedBox(height: 12),
                        DropdownButtonFormField<int>(
                          initialValue: propertyId,
                          decoration: const InputDecoration(
                            labelText: 'العقار',
                            border: OutlineInputBorder(),
                          ),
                          items: properties
                              .map(
                                (property) => DropdownMenuItem<int>(
                                  value: (property['id'] as num).toInt(),
                                  child: Text(
                                    '${property['name'] ?? 'عقار بلا اسم'} — المالك: ${property['owner_name'] ?? 'غير محدد'}',
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              )
                              .toList(),
                          onChanged: isDialogSaving
                              ? null
                              : (value) async {
                                  if (value == null) return;
                                  setDialogState(() {
                                    propertyId = value;
                                    unitId = null;
                                    units = [];
                                  });
                                  try {
                                    final loaded = await DatabaseHelper.instance
                                        .getPropertySaleUnits(value);
                                    if (dialogContext.mounted) {
                                      setDialogState(() => units = loaded);
                                    }
                                  } catch (error) {
                                    if (dialogContext.mounted) {
                                      _showMessage(
                                        'تعذر تحميل الوحدات: $error',
                                      );
                                    }
                                  }
                                },
                        ),
                        if (targetType == 'unit') ...[
                          const SizedBox(height: 12),
                          DropdownButtonFormField<int>(
                            initialValue: unitId,
                            decoration: const InputDecoration(
                              labelText: 'الوحدة',
                              border: OutlineInputBorder(),
                            ),
                            items: units
                                .map(
                                  (unit) => DropdownMenuItem<int>(
                                    value: (unit['id'] as num).toInt(),
                                    child: Text(
                                      'وحدة ${unit['unit_number']} — المالك: ${unit['owner_name'] ?? 'غير محدد'} — الحالة: ${unit['status']} — عقود نشطة: ${unit['active_contract_count']}',
                                    ),
                                  ),
                                )
                                .toList(),
                            validator: (value) =>
                                value == null ? 'حدد وحدة تابعة للعقار' : null,
                            onChanged: isDialogSaving
                                ? null
                                : (value) =>
                                      setDialogState(() => unitId = value),
                          ),
                          if (units.isEmpty)
                            const Padding(
                              padding: EdgeInsets.only(top: 8),
                              child: Text('لا توجد وحدات مسجلة لهذا العقار.'),
                            ),
                        ],
                        const SizedBox(height: 12),
                        DropdownButtonFormField<int>(
                          initialValue: buyerOwnerId,
                          decoration: const InputDecoration(
                            labelText: 'المشتري المقترح (من سجل الملاك)',
                            border: OutlineInputBorder(),
                          ),
                          items: owners
                              .map(
                                (owner) => DropdownMenuItem<int>(
                                  value: (owner['id'] as num).toInt(),
                                  child: Text(owner['name']?.toString() ?? ''),
                                ),
                              )
                              .toList(),
                          validator: (value) => value == null
                              ? 'حدد المشتري الذي سيعتمده المراجع'
                              : value == selectedSellerOwnerId()
                              ? 'يجب أن يختلف المشتري عن مالك العقار/الوحدة'
                              : null,
                          onChanged: isDialogSaving
                              ? null
                              : (value) {
                                  if (value != null) {
                                    setDialogState(() => buyerOwnerId = value);
                                  }
                                },
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: amountController,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: const InputDecoration(
                            labelText: 'سعر البيع المقترح',
                            helperText:
                                'سعر الصفقة الذي سيُعرض للمراجع ويُقفل بعد الإرسال؛ لا يولد قيدًا محاسبيًا.',
                            border: OutlineInputBorder(),
                          ),
                          validator: (value) {
                            final raw = value?.trim() ?? '';
                            if (raw.isEmpty) return 'أدخل سعر البيع المقترح';
                            return _parseMinorUnits(raw) == null
                                ? 'أدخل مبلغًا موجبًا بدقة لا تتجاوز منزلتين عشريتين'
                                : null;
                          },
                        ),
                        const SizedBox(height: 12),
                        OutlinedButton.icon(
                          onPressed: isDialogSaving
                              ? null
                              : () async {
                                  final picked = await showDatePicker(
                                    context: dialogContext,
                                    initialDate: DateTime.parse(
                                      proposedSaleDate,
                                    ),
                                    firstDate: DateTime(1900),
                                    lastDate: DateTime.now(),
                                    helpText: 'تاريخ البيع المقترح والمعتمد',
                                  );
                                  if (picked != null && dialogContext.mounted) {
                                    setDialogState(() {
                                      proposedSaleDate = _toIsoDate(picked);
                                    });
                                  }
                                },
                          icon: const Icon(Icons.calendar_month_outlined),
                          label: Text('تاريخ البيع المقترح: $proposedSaleDate'),
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: reasonController,
                          minLines: 3,
                          maxLines: 5,
                          maxLength: 1000,
                          decoration: const InputDecoration(
                            labelText: 'مبرر/بيان الطلب',
                            border: OutlineInputBorder(),
                            alignLabelWithHint: true,
                          ),
                          validator: (value) => value?.trim().isNotEmpty == true
                              ? null
                              : 'اكتب مبرر الطلب؛ لا يتم تخمين بيانات البيع',
                        ),
                        const SizedBox(height: 8),
                        _activeContractsNotice(
                          _selectedActiveCount(
                            properties: properties,
                            units: units,
                            propertyId: propertyId,
                            targetType: targetType,
                            unitId: unitId,
                          ),
                          isCompact: true,
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'المراجعة تعتمد المشتري والسعر والتاريخ المحددة هنا؛ لا يمكن تغييرها بعد الإرسال. الموافقة لا تنقل الملكية ولا تنشئ قيدًا أو ربحًا أو خسارة.',
                          style: TextStyle(fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: isDialogSaving
                      ? null
                      : () => Navigator.pop(dialogContext),
                  child: const Text('إلغاء'),
                ),
                FilledButton.icon(
                  onPressed: isDialogSaving
                      ? null
                      : () async {
                          if (!formKey.currentState!.validate()) return;
                          final amount = _parseMinorUnits(
                            amountController.text,
                          );
                          if (amount == null) return;
                          setDialogState(() => isDialogSaving = true);
                          try {
                            await DatabaseHelper.instance
                                .createPropertySaleReview(
                                  targetType: targetType,
                                  propertyId: propertyId,
                                  unitId: targetType == 'unit' ? unitId : null,
                                  reason: reasonController.text,
                                  proposedBuyerOwnerId: buyerOwnerId,
                                  proposedAmountMinor: amount,
                                  proposedSaleDate: proposedSaleDate,
                                );
                            if (!dialogContext.mounted) return;
                            setDialogState(() => isDialogSaving = false);
                            Navigator.pop(dialogContext);
                            await _loadReviews();
                            if (mounted) {
                              _showMessage('تم حفظ طلب البيع للمراجعة.');
                            }
                          } catch (error) {
                            if (!dialogContext.mounted) return;
                            setDialogState(() => isDialogSaving = false);
                            _showMessage('تعذر حفظ طلب البيع: $error');
                          }
                        },
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('حفظ للمراجعة'),
                ),
              ],
            ),
          ),
        ),
      );
    } finally {
      reasonController.dispose();
      amountController.dispose();
    }
  }

  Map<String, Object?>? _selectedProperty(
    List<Map<String, Object?>> properties,
    int id,
  ) {
    for (final property in properties) {
      if ((property['id'] as num).toInt() == id) return property;
    }
    return null;
  }

  int _activeCount(Map<String, Object?> row) =>
      (row['active_contract_count'] as num?)?.toInt() ?? 0;

  int _selectedActiveCount({
    required List<Map<String, Object?>> properties,
    required List<Map<String, Object?>> units,
    required int propertyId,
    required String targetType,
    required int? unitId,
  }) {
    if (targetType == 'unit') {
      for (final unit in units) {
        if ((unit['id'] as num).toInt() == unitId) {
          return _activeCount(unit);
        }
      }
      return 0;
    }
    final property = _selectedProperty(properties, propertyId);
    return property == null ? 0 : _activeCount(property);
  }

  Future<void> _showSaleExecutionDialog(Map<String, Object?> review) async {
    final saleReviewId = (review['id'] as num).toInt();
    final snapshot = _decodeSnapshot(review['target_snapshot_json']);
    final rawSellerId = snapshot['seller_owner_id'];
    if (rawSellerId is! num) {
      _showMessage(
        'هذا طلب قديم لا يحفظ هوية المالك عند الطلب؛ ألغِه وأنشئ طلب مراجعة جديدًا.',
      );
      return;
    }
    final sellerOwnerId = rawSellerId.toInt();
    final rawBuyerId = review['proposed_buyer_owner_id'];
    final rawPriceMinor = review['proposed_amount_minor'];
    final proposedDate = DateTime.tryParse(
      review['proposed_sale_date']?.toString() ?? '',
    );
    if (rawBuyerId is! num ||
        rawPriceMinor is! num ||
        rawPriceMinor <= 0 ||
        proposedDate == null) {
      _showMessage(
        'الطلب قديم ولا يتضمن مشتريًا وسعرًا وتاريخًا اعتمدها المراجع؛ ألغِه وأنشئ طلبًا جديدًا.',
      );
      return;
    }
    final buyerOwnerId = rawBuyerId.toInt();
    final salePriceMinor = rawPriceMinor.toInt();
    final proposedSaleDate = DateTime(
      proposedDate.year,
      proposedDate.month,
      proposedDate.day,
    );
    final today = DateTime.now();
    final todayOnly = DateTime(today.year, today.month, today.day);
    if (proposedSaleDate.isAfter(todayOnly)) {
      _showMessage('لا يمكن تنفيذ طلب بيع مؤرخ بتاريخ مستقبلي.');
      return;
    }
    final owners = await DatabaseHelper.instance.getPropertySaleOwners();
    if (!mounted) return;
    final matchingBuyers = owners
        .where((owner) => (owner['id'] as num).toInt() == buyerOwnerId)
        .toList();
    if (matchingBuyers.isEmpty || buyerOwnerId == sellerOwnerId) {
      _showMessage('المشتري المعتمد غير صالح؛ ألغِ الطلب وأعد مراجعته.');
      return;
    }
    final buyerNameAtRequest =
        snapshot['proposed_buyer_owner_name'] ??
        matchingBuyers.single['name'] ??
        'غير محدد';

    final formKey = GlobalKey<FormState>();
    final priceController = TextEditingController(
      text: _formatMinor(salePriceMinor),
    );
    final deedController = TextEditingController();
    final reasonController = TextEditingController();
    var saving = false;
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => StatefulBuilder(
          builder: (dialogContext, setDialogState) => PopScope(
            canPop: !saving,
            child: AlertDialog(
              title: const Text('إتمام البيع ونقل الملكية'),
              scrollable: true,
              content: SizedBox(
                width: 620,
                child: Form(
                  key: formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'البائع المسجل: ${snapshot['seller_owner_name'] ?? review['current_owner_name'] ?? 'غير محدد'}',
                      ),
                      Text('المشتري المعتمد عند الطلب: $buyerNameAtRequest'),
                      const SizedBox(height: 10),
                      DropdownButtonFormField<int>(
                        initialValue: buyerOwnerId,
                        decoration: const InputDecoration(
                          labelText: 'المشتري المعتمد في طلب المراجعة',
                          border: OutlineInputBorder(),
                        ),
                        items: matchingBuyers
                            .map(
                              (owner) => DropdownMenuItem<int>(
                                value: (owner['id'] as num).toInt(),
                                child: Text(owner['name']?.toString() ?? ''),
                              ),
                            )
                            .toList(),
                        onChanged: null,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: priceController,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: const InputDecoration(
                          labelText: 'سعر البيع المعتمد',
                          suffixText: 'بالعملة الافتراضية',
                          helperText: 'لا يمكن تغييره بعد اعتماد طلب المراجعة.',
                          border: OutlineInputBorder(),
                        ),
                        readOnly: true,
                        validator: (value) {
                          final amount = _parseMinorUnits(value ?? '');
                          return amount != null && amount > 0
                              ? null
                              : 'أدخل سعرًا نهائيًا موجبًا بدقة لا تتجاوز منزلتين';
                        },
                      ),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: null,
                        icon: const Icon(Icons.calendar_month_outlined),
                        label: Text(
                          'تاريخ البيع المعتمد: ${_toIsoDate(proposedSaleDate)}',
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: deedController,
                        maxLength: 200,
                        decoration: const InputDecoration(
                          labelText: 'مرجع صك/مستند البيع',
                          border: OutlineInputBorder(),
                        ),
                        validator: (value) => value?.trim().isNotEmpty == true
                            ? null
                            : 'مرجع المستند مطلوب لإثبات الإتمام',
                      ),
                      const SizedBox(height: 8),
                      TextFormField(
                        controller: reasonController,
                        minLines: 2,
                        maxLines: 4,
                        maxLength: 1000,
                        decoration: const InputDecoration(
                          labelText: 'بيان إتمام البيع',
                          border: OutlineInputBorder(),
                          alignLabelWithHint: true,
                        ),
                        validator: (value) => value?.trim().isNotEmpty == true
                            ? null
                            : 'أدخل بيانًا موثقًا',
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'لا يُسمح بالإتمام إذا بقي عقد يغطي تاريخ البيع أو يمتد بعده. نقل الملكية لا ينشئ قيدًا ولا يحسب ربحًا أو خسارة؛ ستبقى التسوية المحاسبية بانتظار إدخال المحاسب وربط قيده اليدوي المرحّل.',
                        style: TextStyle(fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: saving ? null : () => Navigator.pop(dialogContext),
                  child: const Text('إلغاء'),
                ),
                FilledButton.icon(
                  onPressed: saving
                      ? null
                      : () async {
                          if (!formKey.currentState!.validate()) return;
                          final salePriceMinor = _parseMinorUnits(
                            priceController.text,
                          );
                          if (salePriceMinor == null) return;
                          setDialogState(() => saving = true);
                          try {
                            await DatabaseHelper.instance
                                .completePropertySaleExecution(
                                  saleReviewId: saleReviewId,
                                  buyerOwnerId: buyerOwnerId,
                                  salePriceMinor: salePriceMinor,
                                  saleDate: _toIsoDate(proposedSaleDate),
                                  deedReference: deedController.text,
                                  reason: reasonController.text,
                                );
                            if (!dialogContext.mounted) return;
                            Navigator.pop(dialogContext);
                            await _loadReviews();
                            if (mounted) {
                              _showMessage(
                                'تم توثيق نقل الملكية. لم يُنشأ أي قيد؛ التسوية المحاسبية ما زالت مطلوبة.',
                              );
                            }
                          } catch (error) {
                            if (!dialogContext.mounted) return;
                            setDialogState(() => saving = false);
                            _showMessage('تعذر إتمام البيع: $error');
                          }
                        },
                  icon: const Icon(Icons.handshake_outlined),
                  label: const Text('توثيق نقل الملكية'),
                ),
              ],
            ),
          ),
        ),
      );
    } finally {
      priceController.dispose();
      deedController.dispose();
      reasonController.dispose();
    }
  }

  Future<void> _showSaleAccountingDialog(Map<String, Object?> review) async {
    final executionId = (review['sale_execution_id'] as num?)?.toInt();
    if (executionId == null) return;
    final previousRecordId = (review['accounting_record_id'] as num?)?.toInt();
    final bookValueController = TextEditingController(
      text: review['accounting_book_value_minor'] is num
          ? _formatMinor(review['accounting_book_value_minor'])
          : '',
    );
    final journalIdController = TextEditingController(
      text: review['manual_journal_entry_id']?.toString() ?? '',
    );
    final noteController = TextEditingController(
      text: review['accounting_note']?.toString() ?? '',
    );
    final formKey = GlobalKey<FormState>();
    var saving = false;
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => StatefulBuilder(
          builder: (dialogContext, setDialogState) => PopScope(
            canPop: !saving,
            child: AlertDialog(
              title: Text(
                previousRecordId == null
                    ? 'توثيق التسوية المحاسبية'
                    : 'إضافة تصحيح محاسبي موثق',
              ),
              scrollable: true,
              content: SizedBox(
                width: 560,
                child: Form(
                  key: formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        'أدخل القيمة الدفترية المعتمدة واربط قيدًا يدويًا مرحّلًا ومتوازنًا. النظام لا ينشئ قيدًا ولا يحسب ربحًا أو خسارة.',
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: bookValueController,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: const InputDecoration(
                          labelText: 'القيمة الدفترية المعتمدة',
                          border: OutlineInputBorder(),
                        ),
                        validator: (value) =>
                            _parseMinorUnits(value ?? '') != null
                            ? null
                            : 'أدخل قيمة دفترية صفرًا أو أكثر بدقة منزلتين',
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: journalIdController,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'رقم القيد اليدوي المرحّل',
                          helperText:
                              'القيد يُنشأ ويرحّل يدويًا من شاشة القيود.',
                          border: OutlineInputBorder(),
                        ),
                        validator: (value) {
                          final id = int.tryParse(value?.trim() ?? '');
                          return id != null && id > 0
                              ? null
                              : 'أدخل رقم قيد موجبًا مرحّلًا ومتوازنًا';
                        },
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: noteController,
                        minLines: 3,
                        maxLines: 5,
                        maxLength: 1000,
                        decoration: const InputDecoration(
                          labelText: 'بيان اعتماد المحاسب',
                          border: OutlineInputBorder(),
                          alignLabelWithHint: true,
                        ),
                        validator: (value) => value?.trim().isNotEmpty == true
                            ? null
                            : 'مبرر الاعتماد مطلوب',
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: saving ? null : () => Navigator.pop(dialogContext),
                  child: const Text('إلغاء'),
                ),
                FilledButton.icon(
                  onPressed: saving
                      ? null
                      : () async {
                          if (!formKey.currentState!.validate()) return;
                          final bookValueMinor = _parseMinorUnits(
                            bookValueController.text,
                          );
                          final journalEntryId = int.tryParse(
                            journalIdController.text.trim(),
                          );
                          if (bookValueMinor == null ||
                              journalEntryId == null) {
                            return;
                          }
                          setDialogState(() => saving = true);
                          try {
                            await DatabaseHelper.instance
                                .recordPropertySaleAccounting(
                                  saleExecutionId: executionId,
                                  bookValueMinor: bookValueMinor,
                                  manualJournalEntryId: journalEntryId,
                                  note: noteController.text,
                                  supersedesRecordId: previousRecordId,
                                );
                            if (!dialogContext.mounted) return;
                            Navigator.pop(dialogContext);
                            await _loadReviews();
                            if (mounted) {
                              _showMessage(
                                'تم توثيق اعتماد المحاسب وربط القيد اليدوي؛ لم ينشئ النظام أي قيد تلقائي.',
                              );
                            }
                          } catch (error) {
                            if (!dialogContext.mounted) return;
                            setDialogState(() => saving = false);
                            _showMessage('تعذر حفظ التسوية: $error');
                          }
                        },
                  icon: const Icon(Icons.account_balance_outlined),
                  label: Text(
                    previousRecordId == null ? 'اعتماد يدوي' : 'حفظ التصحيح',
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    } finally {
      bookValueController.dispose();
      journalIdController.dispose();
      noteController.dispose();
    }
  }

  Future<void> _showReviewDialog(
    Map<String, Object?> review, {
    required bool accept,
  }) async {
    final snapshot = _decodeSnapshot(review['target_snapshot_json']);
    final proposedBuyerName =
        snapshot['proposed_buyer_owner_name'] ??
        review['proposed_buyer_name'] ??
        'غير محدد';
    final reasonController = TextEditingController();
    final formKey = GlobalKey<FormState>();
    var saving = false;
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => StatefulBuilder(
          builder: (dialogContext, setDialogState) => PopScope(
            canPop: !saving,
            child: AlertDialog(
              title: Text(accept ? 'اعتماد نتيجة المراجعة' : 'رفض طلب البيع'),
              scrollable: true,
              content: SizedBox(
                width: 500,
                child: Form(
                  key: formKey,
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'شروط الصفقة التي سيشملها القرار:\n'
                          'المشتري: $proposedBuyerName\n'
                          'السعر: ${_formatMinor(review['proposed_amount_minor'])}\n'
                          'التاريخ: ${review['proposed_sale_date'] ?? 'غير محدد'}',
                          textAlign: TextAlign.start,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          accept
                              ? 'الموافقة تخص هذه الشروط نفسها فقط؛ لا تعني إتمام البيع أو إنشاء أي قيد، ولا يمكن تغيير المشتري أو السعر أو التاريخ أثناء التنفيذ.'
                              : 'سيبقى الطلب وسجلّه محفوظين؛ يمكن إنشاء طلب جديد لاحقًا بسبب موثق.',
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: reasonController,
                          minLines: 3,
                          maxLines: 5,
                          maxLength: 1000,
                          decoration: const InputDecoration(
                            labelText: 'مبرر القرار',
                            border: OutlineInputBorder(),
                          ),
                          validator: (value) => value?.trim().isNotEmpty == true
                              ? null
                              : 'مبرر القرار الموثق مطلوب',
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: saving ? null : () => Navigator.pop(dialogContext),
                  child: const Text('رجوع'),
                ),
                FilledButton(
                  onPressed: saving
                      ? null
                      : () async {
                          if (!formKey.currentState!.validate()) return;
                          setDialogState(() => saving = true);
                          try {
                            await DatabaseHelper.instance
                                .reviewPropertySaleRequest(
                                  saleReviewId: (review['id'] as num).toInt(),
                                  accept: accept,
                                  reason: reasonController.text,
                                );
                            if (!dialogContext.mounted) return;
                            setDialogState(() => saving = false);
                            Navigator.pop(dialogContext);
                            await _loadReviews();
                            if (mounted) {
                              _showMessage(
                                accept
                                    ? 'تم اعتماد نتيجة المراجعة اليدوية فقط.'
                                    : 'تم رفض الطلب وحفظ المبرر.',
                              );
                            }
                          } catch (error) {
                            if (!dialogContext.mounted) return;
                            setDialogState(() => saving = false);
                            _showMessage('تعذر حفظ قرار المراجعة: $error');
                          }
                        },
                  child: Text(accept ? 'اعتماد المراجعة' : 'تأكيد الرفض'),
                ),
              ],
            ),
          ),
        ),
      );
    } finally {
      reasonController.dispose();
    }
  }

  Future<void> _showCancelDialog(Map<String, Object?> review) async {
    final reasonController = TextEditingController();
    final formKey = GlobalKey<FormState>();
    var saving = false;
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => StatefulBuilder(
          builder: (dialogContext, setDialogState) => PopScope(
            canPop: !saving,
            child: AlertDialog(
              title: const Text('إلغاء طلب البيع'),
              scrollable: true,
              content: SizedBox(
                width: 500,
                child: SingleChildScrollView(
                  child: Form(
                    key: formKey,
                    child: TextFormField(
                      controller: reasonController,
                      minLines: 3,
                      maxLines: 5,
                      maxLength: 1000,
                      decoration: const InputDecoration(
                        labelText: 'سبب الإلغاء الموثق',
                        border: OutlineInputBorder(),
                      ),
                      validator: (value) => value?.trim().isNotEmpty == true
                          ? null
                          : 'سبب الإلغاء مطلوب',
                    ),
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: saving ? null : () => Navigator.pop(dialogContext),
                  child: const Text('رجوع'),
                ),
                FilledButton(
                  onPressed: saving
                      ? null
                      : () async {
                          if (!formKey.currentState!.validate()) return;
                          setDialogState(() => saving = true);
                          try {
                            await DatabaseHelper.instance
                                .cancelPropertySaleReview(
                                  saleReviewId: (review['id'] as num).toInt(),
                                  reason: reasonController.text,
                                );
                            if (!dialogContext.mounted) return;
                            setDialogState(() => saving = false);
                            Navigator.pop(dialogContext);
                            await _loadReviews();
                            if (mounted) {
                              _showMessage('أُلغي الطلب مع حفظ السبب.');
                            }
                          } catch (error) {
                            if (!dialogContext.mounted) return;
                            setDialogState(() => saving = false);
                            _showMessage('تعذر إلغاء الطلب: $error');
                          }
                        },
                  child: const Text('تأكيد الإلغاء'),
                ),
              ],
            ),
          ),
        ),
      );
    } finally {
      reasonController.dispose();
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Map<String, Object?> _decodeSnapshot(Object? value) {
    if (value is! String || value.isEmpty) return const {};
    try {
      final decoded = jsonDecode(value);
      return decoded is Map<String, Object?> ? decoded : const {};
    } catch (_) {
      return const {};
    }
  }

  String _statusLabel(String? status) => switch (status) {
    'pending' => 'بانتظار المراجعة',
    'accepted' => 'اعتمدت نتيجة المراجعة — ليس إثبات بيع',
    'rejected' => 'مرفوض',
    'cancelled' => 'ملغي',
    _ => 'حالة غير معروفة',
  };

  String _saleEventLabel(String? eventType) => switch (eventType) {
    'requested' => 'إنشاء طلب مراجعة',
    'accepted' => 'اعتماد نتيجة المراجعة',
    'rejected' => 'رفض الطلب',
    'cancelled' => 'إلغاء الطلب',
    'executed' => 'إتمام البيع ونقل الملكية',
    'accounting_approved' => 'اعتماد التسوية المحاسبية',
    'accounting_corrected' => 'تصحيح التسوية المحاسبية',
    _ => eventType ?? 'حدث بيع',
  };

  Color _statusColor(BuildContext context, String? status) => switch (status) {
    'pending' => Theme.of(context).colorScheme.tertiary,
    'accepted' => Theme.of(context).colorScheme.primary,
    'rejected' || 'cancelled' => Theme.of(context).colorScheme.error,
    _ => Theme.of(context).colorScheme.outline,
  };

  String _formatMinor(Object? value) {
    if (value is! num) return 'غير محددة';
    final amount = value.toInt();
    return '${amount ~/ 100}.${(amount % 100).abs().toString().padLeft(2, '0')}';
  }

  String _toIsoDate(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

  int? _parseMinorUnits(String raw) {
    var value = raw.trim();
    if (value.isEmpty) return null;
    const arabic = '٠١٢٣٤٥٦٧٨٩';
    const persian = '۰۱۲۳۴۵۶۷۸۹';
    final converted = StringBuffer();
    for (final rune in value.runes) {
      final char = String.fromCharCode(rune);
      final arabicIndex = arabic.indexOf(char);
      final persianIndex = persian.indexOf(char);
      if (arabicIndex >= 0) {
        converted.write(arabicIndex);
      } else if (persianIndex >= 0) {
        converted.write(persianIndex);
      } else if (char == '٬' || char == ',') {
        continue;
      } else if (char == '٫') {
        converted.write('.');
      } else {
        converted.write(char);
      }
    }
    value = converted.toString().replaceAll(' ', '');
    final match = RegExp(r'^(\d+)(?:\.(\d{1,2}))?$').firstMatch(value);
    if (match == null) return null;
    try {
      final whole = int.parse(match.group(1)!);
      final fraction = int.parse((match.group(2) ?? '').padRight(2, '0'));
      return whole * 100 + fraction;
    } on FormatException {
      return null;
    } on UnsupportedError {
      return null;
    }
  }

  Widget _activeContractsNotice(int count, {bool isCompact = false}) {
    if (count <= 0) {
      return Text(
        'لا توجد عقود نشطة معروفة على هذا العقار وقت الطلب.',
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
      );
    }
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        'تنبيه: يوجد $count عقد نشط. طلب البيع لا يلغي العقد ولا يغيّر حالة الوحدة. راجع أثره يدويًا في مسار مستقل.',
        style: TextStyle(
          color: Theme.of(context).colorScheme.onErrorContainer,
          fontSize: isCompact ? 12 : null,
        ),
      ),
    );
  }

  Widget _buildReviewCard(Map<String, Object?> review) {
    final status = review['status']?.toString();
    final snapshot = _decodeSnapshot(review['target_snapshot_json']);
    final propertyName =
        snapshot['property_name']?.toString() ??
        review['current_property_name']?.toString() ??
        'عقار';
    final unitNumber =
        snapshot['unit_number']?.toString() ??
        review['current_unit_number']?.toString();
    final isUnit = review['target_type'] == 'unit';
    final title = isUnit
        ? '$propertyName — وحدة ${unitNumber ?? 'غير محددة'}'
        : '$propertyName — العقار كاملًا';
    final activeAtRequest =
        (review['active_contract_count_at_request'] as num?)?.toInt() ?? 0;
    final activeCurrent =
        (review['active_contract_count_current'] as num?)?.toInt() ?? 0;
    final saleExecuted =
        review['sale_execution_id'] is num &&
        review['transfer_applied_at'] != null;
    final accountingComplete = review['accounting_record_id'] is num;
    final snapshotSellerId = (snapshot['seller_owner_id'] as num?)?.toInt();
    final currentOwnerId = (review['current_owner_id'] as num?)?.toInt();
    final sellerStillCurrent =
        snapshotSellerId != null && currentOwnerId == snapshotSellerId;
    final hasApprovedTerms =
        review['proposed_buyer_owner_id'] is num &&
        (review['proposed_buyer_owner_id'] as num) > 0 &&
        review['proposed_amount_minor'] is num &&
        (review['proposed_amount_minor'] as num) > 0 &&
        DateTime.tryParse(review['proposed_sale_date']?.toString() ?? '') !=
            null;
    final canReview =
        status == 'pending' &&
        PermissionRuntime.allows(
          'property_sales',
          AppPermissionAction.reviewApprove,
        );
    final canExecute =
        status == 'accepted' &&
        !saleExecuted &&
        hasApprovedTerms &&
        sellerStillCurrent &&
        PermissionRuntime.allows('property_sales', AppPermissionAction.post);
    final canRecordAccounting =
        saleExecuted &&
        PermissionRuntime.allows('accounting', AppPermissionAction.post);
    final canCancel =
        (status == 'pending' || status == 'accepted') &&
        !saleExecuted &&
        PermissionRuntime.allows('property_sales', AppPermissionAction.edit);
    final statusLabel = !saleExecuted
        ? _statusLabel(status)
        : accountingComplete
        ? 'تم نقل الملكية واعتماد التسوية يدويًا'
        : 'تم نقل الملكية — التسوية المحاسبية معلقة';
    final statusColor = !saleExecuted
        ? _statusColor(context, status)
        : accountingComplete
        ? Theme.of(context).colorScheme.primary
        : Theme.of(context).colorScheme.tertiary;
    final reviewId = (review['id'] as num).toInt();
    final eventFuture = _eventFutures[reviewId];

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: ExpansionTile(
        key: PageStorageKey('sale-review-${review['id']}'),
        onExpansionChanged: (expanded) {
          if (expanded) {
            _expandedReviewIds.add(reviewId);
            if (!_eventFutures.containsKey(reviewId)) {
              setState(() {
                _eventFutures[reviewId] = DatabaseHelper.instance
                    .getPropertySaleReviewEvents(reviewId);
              });
            }
          } else {
            _expandedReviewIds.remove(reviewId);
          }
        },
        tilePadding: const EdgeInsetsDirectional.fromSTEB(18, 8, 18, 8),
        childrenPadding: const EdgeInsetsDirectional.fromSTEB(18, 0, 18, 16),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(
          'طلب #${review['id']} • ${review['requester_name'] ?? 'مستخدم'} • ${review['requested_at'] ?? ''}',
        ),
        trailing: _StatusBadge(label: statusLabel, color: statusColor),
        children: [
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: Wrap(
              spacing: 20,
              runSpacing: 8,
              children: [
                Text(
                  'القيمة المقترحة: ${_formatMinor(review['proposed_amount_minor'])}',
                ),
                Text(
                  'المشتري المقترح: ${snapshot['proposed_buyer_owner_name'] ?? review['proposed_buyer_name'] ?? 'غير محدد'}',
                ),
                Text(
                  'تاريخ البيع المقترح: ${review['proposed_sale_date'] ?? 'غير محدد'}',
                ),
                Text('العقود النشطة وقت الطلب: $activeAtRequest'),
                Text('العقود النشطة حاليًا: $activeCurrent'),
                Text(
                  'مالك الهدف عند الطلب: ${snapshot['seller_owner_name'] ?? 'غير موثق'}',
                ),
                Text(
                  'المالك الحالي: ${review['current_owner_name'] ?? 'غير محدد'}',
                ),
              ],
            ),
          ),
          if (status == 'accepted' && !saleExecuted && !sellerStillCurrent)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'تغير المالك منذ إنشاء الطلب أو أن الطلب قديم بلا لقطة موثوقة؛ لا تنفذ البيع قبل إلغاء الطلب وإعادة مراجعته.',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (status == 'accepted' && !saleExecuted && !hasApprovedTerms)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'طلب قديم بلا شروط مشتري وسعر وتاريخ معتمدة؛ لا يمكن تنفيذه. ألغِه وأنشئ طلبًا جديدًا.',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (saleExecuted) ...[
            const SizedBox(height: 10),
            Card(
              color: Theme.of(context).colorScheme.surfaceContainerLow,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Wrap(
                  spacing: 20,
                  runSpacing: 8,
                  children: [
                    Text(
                      'المشتري: ${review['buyer_owner_name_snapshot'] ?? 'غير محدد'}',
                    ),
                    Text('تاريخ النفاذ: ${review['sale_date'] ?? ''}'),
                    Text(
                      'سعر البيع: ${_formatMinor(review['sale_price_minor'])}',
                    ),
                    Text('مرجع الصك: ${review['deed_reference'] ?? ''}'),
                    if (accountingComplete) ...[
                      Text(
                        'القيمة الدفترية المعتمدة: ${_formatMinor(review['accounting_book_value_minor'])}',
                      ),
                      Text(
                        'رقم القيد اليدوي: ${review['manual_journal_entry_id']}',
                      ),
                    ] else
                      const Text('التسوية المحاسبية: بانتظار اعتماد المحاسب'),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 8),
          _activeContractsNotice(activeCurrent),
          const SizedBox(height: 8),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: Text('مبرر الطلب: ${review['reason'] ?? ''}'),
          ),
          if (review['review_reason'] != null)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: Text(
                'مبرر المراجعة (${review['reviewer_name'] ?? 'مراجع'}): ${review['review_reason']}',
              ),
            ),
          if (review['cancel_reason'] != null)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: Text('سبب الإلغاء: ${review['cancel_reason']}'),
            ),
          const SizedBox(height: 6),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: Text(
              'مصدر بيانات الهدف: ${snapshot['source'] ?? 'غير معروف'}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (canReview) ...[
                FilledButton.icon(
                  onPressed: () => _showReviewDialog(review, accept: true),
                  icon: const Icon(Icons.fact_check_outlined),
                  label: const Text('اعتماد نتيجة المراجعة'),
                ),
                OutlinedButton.icon(
                  onPressed: () => _showReviewDialog(review, accept: false),
                  icon: const Icon(Icons.block_outlined),
                  label: const Text('رفض الطلب'),
                ),
              ],
              if (canExecute)
                FilledButton.icon(
                  onPressed: () => _showSaleExecutionDialog(review),
                  icon: const Icon(Icons.handshake_outlined),
                  label: const Text('إتمام البيع ونقل الملكية'),
                ),
              if (canRecordAccounting)
                OutlinedButton.icon(
                  onPressed: () => _showSaleAccountingDialog(review),
                  icon: const Icon(Icons.account_balance_outlined),
                  label: Text(
                    accountingComplete
                        ? 'تصحيح التسوية المحاسبية'
                        : 'توثيق التسوية المحاسبية',
                  ),
                ),
              if (canCancel)
                TextButton.icon(
                  onPressed: () => _showCancelDialog(review),
                  icon: const Icon(Icons.cancel_outlined),
                  label: const Text('إلغاء الطلب'),
                ),
            ],
          ),
          const Divider(height: 24),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: Text(
              'سجل الأحداث',
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          if (eventFuture == null)
            const Text('افتح البطاقة لتحميل سجل الأحداث.'),
          if (eventFuture != null)
            FutureBuilder<List<Map<String, Object?>>>(
              future: eventFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Padding(
                    padding: EdgeInsets.all(12),
                    child: LinearProgressIndicator(),
                  );
                }
                if (snapshot.hasError) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('تعذر تحميل سجل الأحداث: ${snapshot.error}'),
                      TextButton.icon(
                        onPressed: () => setState(() {
                          _eventFutures[reviewId] = DatabaseHelper.instance
                              .getPropertySaleReviewEvents(reviewId);
                        }),
                        icon: const Icon(Icons.refresh),
                        label: const Text('إعادة المحاولة'),
                      ),
                    ],
                  );
                }
                final events = snapshot.data ?? const [];
                return Column(
                  children: events
                      .map(
                        (event) => ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.history, size: 18),
                          title: Text(
                            '${_saleEventLabel(event['event_type']?.toString())} — ${event['user_name'] ?? 'مستخدم'}',
                          ),
                          subtitle: Text(
                            '${event['created_at'] ?? ''}\n${event['reason'] ?? ''}',
                          ),
                        ),
                      )
                      .toList(),
                );
              },
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final canAdd = PermissionRuntime.allows(
      'property_sales',
      AppPermissionAction.add,
    );
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'مراجعة وتنفيذ بيع العقار والوحدة',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                ),
              ),
              IconButton(
                tooltip: 'تحديث القائمة',
                onPressed: _isLoading ? null : _loadReviews,
                icon: const Icon(Icons.refresh),
              ),
              if (canAdd) ...[
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: _isLoading ? null : _showCreateDialog,
                  icon: const Icon(Icons.add_business_outlined),
                  label: const Text('طلب مراجعة بيع'),
                ),
              ],
            ],
          ),
          const SizedBox(height: 10),
          Card(
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            child: const Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                'يمر البيع بثلاث خطوات منفصلة: اعتماد المراجعة، ثم توثيق الصك والسعر وتاريخ نقل الملكية، ثم اعتماد المحاسب للقيمة الدفترية وربط قيد يدوي مرحّل. يمنع الإتمام إذا امتد عقد غير ملغى إلى تاريخ البيع أو بعده. لا ينشئ النظام قيودًا ولا يحسب أرباحًا أو خسائر تلقائيًا.',
              ),
            ),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _loadError != null
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('تعذر تحميل الطلبات: $_loadError'),
                        const SizedBox(height: 8),
                        FilledButton.icon(
                          onPressed: _loadReviews,
                          icon: const Icon(Icons.refresh),
                          label: const Text('إعادة المحاولة'),
                        ),
                      ],
                    ),
                  )
                : _reviews.isEmpty
                ? const Center(child: Text('لا توجد طلبات بيع للمراجعة.'))
                : RefreshIndicator(
                    onRefresh: _loadReviews,
                    child: ListView.builder(
                      physics: const AlwaysScrollableScrollPhysics(),
                      itemCount: _reviews.length,
                      itemBuilder: (context, index) =>
                          _buildReviewCard(_reviews[index]),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
