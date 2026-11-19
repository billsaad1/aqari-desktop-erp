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
    if (!mounted) return;
    if (properties.isEmpty) {
      _showMessage('أضف عقارًا أولًا قبل إنشاء طلب مراجعة بيع.');
      return;
    }

    final formKey = GlobalKey<FormState>();
    final reasonController = TextEditingController();
    final amountController = TextEditingController();
    var targetType = 'property';
    var propertyId = (properties.first['id'] as num).toInt();
    int? unitId;
    String? proposedSaleDate;
    var units = await DatabaseHelper.instance.getPropertySaleUnits(propertyId);
    if (!mounted) {
      reasonController.dispose();
      amountController.dispose();
      return;
    }
    var isDialogSaving = false;

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
                                      'وحدة ${unit['unit_number']} — الحالة: ${unit['status']} — عقود نشطة: ${unit['active_contract_count']}',
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
                        TextFormField(
                          controller: amountController,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: const InputDecoration(
                            labelText: 'القيمة المقترحة (اختياري)',
                            helperText:
                                'أدخلها فقط إذا كانت معلومة؛ لن تُستنتج أو تُرحّل محاسبيًا.',
                            border: OutlineInputBorder(),
                          ),
                          validator: (value) {
                            final raw = value?.trim() ?? '';
                            if (raw.isEmpty) return null;
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
                                    initialDate: DateTime.now(),
                                    firstDate: DateTime(1900),
                                    lastDate: DateTime(2200),
                                    helpText: 'التاريخ المقترح للبيع (اختياري)',
                                  );
                                  if (picked != null && dialogContext.mounted) {
                                    setDialogState(() {
                                      proposedSaleDate = _toIsoDate(picked);
                                    });
                                  }
                                },
                          icon: const Icon(Icons.calendar_month_outlined),
                          label: Text(
                            proposedSaleDate == null
                                ? 'تحديد تاريخ مقترح (اختياري)'
                                : 'التاريخ المقترح: $proposedSaleDate',
                          ),
                        ),
                        if (proposedSaleDate != null)
                          Align(
                            alignment: AlignmentDirectional.centerStart,
                            child: TextButton(
                              onPressed: isDialogSaving
                                  ? null
                                  : () => setDialogState(
                                      () => proposedSaleDate = null,
                                    ),
                              child: const Text('مسح التاريخ'),
                            ),
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
                          'حفظ الطلب أو الموافقة عليه لا يثبت إتمام البيع، ولا يغيّر المالك أو حالة الوحدة أو العقود، ولا ينشئ قيدًا أو ربحًا أو خسارة.',
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
                          setDialogState(() => isDialogSaving = true);
                          try {
                            await DatabaseHelper.instance
                                .createPropertySaleReview(
                                  targetType: targetType,
                                  propertyId: propertyId,
                                  unitId: targetType == 'unit' ? unitId : null,
                                  reason: reasonController.text,
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

  Future<void> _showReviewDialog(
    Map<String, Object?> review, {
    required bool accept,
  }) async {
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
                          accept
                              ? 'الموافقة هنا تخص نتيجة المراجعة اليدوية فقط، ولا تعني إتمام البيع أو إنشاء أي قيد.'
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
    final canReview =
        status == 'pending' &&
        PermissionRuntime.allows(
          'property_sales',
          AppPermissionAction.reviewApprove,
        );
    final canCancel =
        (status == 'pending' || status == 'accepted') &&
        PermissionRuntime.allows('property_sales', AppPermissionAction.edit);
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
        trailing: _StatusBadge(
          label: _statusLabel(status),
          color: _statusColor(context, status),
        ),
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
                  'تاريخ البيع المقترح: ${review['proposed_sale_date'] ?? 'غير محدد'}',
                ),
                Text('العقود النشطة وقت الطلب: $activeAtRequest'),
                Text('العقود النشطة حاليًا: $activeCurrent'),
              ],
            ),
          ),
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
                            '${event['event_type']} — ${event['user_name'] ?? 'مستخدم'}',
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
                  'مراجعة بيع العقار والوحدة',
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
                'هذه شاشة مراجعة يدوية فقط. اعتماد المراجعة لا يعني إتمام البيع، ولا يغيّر الملكية أو الإشغال أو العقود، ولا ينشئ قيدًا أو ربحًا/خسارة. لا يُرحّل أي أثر قبل مراجعة مستقلة واعتماد محاسبي موثق.',
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
