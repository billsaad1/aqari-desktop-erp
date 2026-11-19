import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/erp_data_table.dart';
import '../../core/pdf_preview_dialog.dart';
import '../../core/permission_policy.dart';
import '../../core/property_unit_inquiry_pdf.dart';
import '../../database/database_helper.dart';
import '../../providers/reports_provider.dart';

class PropertyUnitInquiryScreen extends StatefulWidget {
  const PropertyUnitInquiryScreen({super.key});

  @override
  State<PropertyUnitInquiryScreen> createState() =>
      _PropertyUnitInquiryScreenState();
}

class _PropertyUnitInquiryScreenState extends State<PropertyUnitInquiryScreen> {
  late int? _authorizedUserId;
  late String? _authorizedRole;
  late bool _hadReportsViewAccess;

  @override
  void initState() {
    super.initState();
    _authorizedUserId = PermissionRuntime.userId;
    _authorizedRole = PermissionRuntime.role;
    _hadReportsViewAccess = PermissionRuntime.allows(
      'reports',
      AppPermissionAction.view,
    );
    PermissionRuntime.authorizationRevision.addListener(
      _handleAuthorizationChange,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        Provider.of<ReportsProvider>(
          context,
          listen: false,
        ).loadPropertyInquiryProperties(),
      );
    });
  }

  @override
  void dispose() {
    PermissionRuntime.authorizationRevision.removeListener(
      _handleAuthorizationChange,
    );
    super.dispose();
  }

  void _handleAuthorizationChange() {
    if (!mounted) return;
    final canViewReports = PermissionRuntime.allows(
      'reports',
      AppPermissionAction.view,
    );
    final identityChanged =
        PermissionRuntime.userId != _authorizedUserId ||
        PermissionRuntime.role != _authorizedRole;
    final accessRestored = canViewReports && !_hadReportsViewAccess;

    if (!canViewReports || identityChanged) {
      final provider = context.read<ReportsProvider>();
      provider.clearReportResults();
      if (canViewReports) {
        unawaited(provider.loadPropertyInquiryProperties());
      }
    } else if (accessRestored) {
      unawaited(
        context.read<ReportsProvider>().loadPropertyInquiryProperties(),
      );
    }

    _authorizedUserId = PermissionRuntime.userId;
    _authorizedRole = PermissionRuntime.role;
    _hadReportsViewAccess = canViewReports;
    setState(() {});
  }

  Future<void> _previewPdf(
    ReportsProvider provider, {
    required bool save,
  }) async {
    try {
      PermissionRuntime.require('reports', AppPermissionAction.view);
      final propertyId = provider.selectedInquiryPropertyId;
      final generatedAt = provider.propertyInquiryAsOf;
      if (propertyId == null || generatedAt == null) {
        throw StateError('اختر عقارًا وحمّل بياناته قبل إعداد التقرير');
      }
      final property = provider.propertyInquiryProperties.firstWhere(
        (item) => (item['id'] as num).toInt() == propertyId,
      );
      final companyInfo = await DatabaseHelper.instance.getCompanyInfo();
      final bytes = await PropertyUnitInquiryPdf.build(
        companyInfo: companyInfo,
        property: property,
        units: provider.propertyInquiryUnits,
        generatedAt: generatedAt,
      );
      if (!mounted) return;
      await PdfDocumentPreviewDialog.show(
        context: context,
        bytes: bytes,
        fileName: 'استعلام_الوحدات_${property['name']}',
        preferredIntent: save
            ? PdfPreviewIntent.save
            : PdfPreviewIntent.printDocument,
        permissionModule: 'reports',
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذر إعداد تقرير العقار والوحدات: $error')),
      );
    }
  }

  String _statusLabel(Object? status) {
    final value = status?.toString().trim() ?? '';
    return value.isEmpty ? 'غير محددة' : value;
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ReportsProvider>(
      builder: (context, provider, child) {
        if (!PermissionRuntime.allows('reports', AppPermissionAction.view)) {
          return const Center(
            child: Text('لا تملك صلاحية عرض التقارير والاستعلامات.'),
          );
        }
        Map<String, dynamic>? selectedProperty;
        for (final item in provider.propertyInquiryProperties) {
          if ((item['id'] as num?)?.toInt() ==
              provider.selectedInquiryPropertyId) {
            selectedProperty = item;
            break;
          }
        }
        final canPreview =
            provider.propertyInquiryUnitsLoaded &&
            PermissionRuntime.allows('reports', AppPermissionAction.view);
        final canPrint =
            canPreview &&
            PermissionRuntime.allows('reports', AppPermissionAction.print);

        return Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'استعلام العقار والوحدات',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  if (canPrint) ...[
                    ElevatedButton.icon(
                      onPressed: () => _previewPdf(provider, save: false),
                      icon: const Icon(Icons.print),
                      label: const Text('معاينة / طباعة'),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed: () => _previewPdf(provider, save: true),
                      icon: const Icon(Icons.picture_as_pdf),
                      label: const Text('حفظ PDF'),
                    ),
                  ] else
                    OutlinedButton.icon(
                      onPressed: canPreview
                          ? () => _previewPdf(provider, save: false)
                          : null,
                      icon: const Icon(Icons.picture_as_pdf),
                      label: const Text('معاينة PDF'),
                    ),
                ],
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<int>(
                      key: ValueKey(provider.selectedInquiryPropertyId),
                      initialValue: provider.selectedInquiryPropertyId,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'اختر العقار',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.apartment),
                      ),
                      items: provider.propertyInquiryProperties.map((item) {
                        final id = (item['id'] as num).toInt();
                        return DropdownMenuItem<int>(
                          value: id,
                          child: Text(item['name']?.toString() ?? ''),
                        );
                      }).toList(),
                      onChanged:
                          provider.isPropertyInquiryLoading ||
                              provider.propertyInquiryProperties.isEmpty
                          ? null
                          : (propertyId) {
                              if (propertyId != null) {
                                unawaited(
                                  provider.loadPropertyInquiryUnits(propertyId),
                                );
                              }
                            },
                    ),
                  ),
                  const SizedBox(width: 12),
                  IconButton.filledTonal(
                    tooltip: 'تحديث قائمة العقارات',
                    onPressed: provider.isPropertyInquiryLoading
                        ? null
                        : () => unawaited(
                            provider.loadPropertyInquiryProperties(),
                          ),
                    icon: const Icon(Icons.refresh),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (provider.isPropertyInquiryLoading)
                const LinearProgressIndicator(),
              if (provider.propertyInquiryErrorMessage != null)
                _ErrorPanel(
                  message: provider.propertyInquiryErrorMessage!,
                  onRetry: () => unawaited(
                    provider.selectedInquiryPropertyId == null
                        ? provider.loadPropertyInquiryProperties()
                        : provider.loadPropertyInquiryUnits(
                            provider.selectedInquiryPropertyId!,
                          ),
                  ),
                )
              else if (provider.propertyInquiryPropertiesLoaded &&
                  provider.propertyInquiryProperties.isEmpty)
                const Expanded(
                  child: _EmptyPanel(message: 'لا توجد عقارات مسجلة حتى الآن.'),
                )
              else if (provider.selectedInquiryPropertyId == null)
                const Expanded(
                  child: _EmptyPanel(
                    message: 'اختر عقارًا لعرض وحداته المسجلة.',
                  ),
                )
              else if (!provider.propertyInquiryUnitsLoaded &&
                  !provider.isPropertyInquiryLoading)
                const Expanded(
                  child: _EmptyPanel(
                    message: 'اختر عقارًا لعرض وحداته المسجلة.',
                  ),
                )
              else if (provider.propertyInquiryUnitsLoaded &&
                  selectedProperty != null)
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Row(
                            children: [
                              const Icon(Icons.info_outline),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  'الحالة المعروضة تخص وقت الاستعلام فقط، ولا تمثل سجلًا تاريخيًا أو إثباتًا لإتمام بيع.',
                                  textDirection: TextDirection.rtl,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'العقار: ${selectedProperty['name'] ?? ''}  •  وقت الاستعلام: ${_formatTimestamp(provider.propertyInquiryAsOf!)}',
                        textDirection: TextDirection.rtl,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 12),
                      if (provider.propertyInquiryUnits.isEmpty)
                        const Expanded(
                          child: _EmptyPanel(
                            message:
                                'لا توجد وحدات مسجلة لهذا العقار وقت الاستعلام.',
                          ),
                        )
                      else
                        Expanded(
                          child: SingleChildScrollView(
                            child: ErpDataTable(
                              columns: const [
                                DataColumn(label: Text('رقم الوحدة')),
                                DataColumn(label: Text('الحالة الحالية')),
                                DataColumn(label: Text('العقود النشطة')),
                              ],
                              rows: provider.propertyInquiryUnits.map((unit) {
                                final count =
                                    (unit['active_contract_count'] as num?)
                                        ?.toInt() ??
                                    0;
                                return DataRow(
                                  cells: [
                                    DataCell(
                                      Text(
                                        unit['unit_number']?.toString() ?? '',
                                        textDirection: TextDirection.ltr,
                                      ),
                                    ),
                                    DataCell(
                                      Text(_statusLabel(unit['status'])),
                                    ),
                                    DataCell(Text(count.toString())),
                                  ],
                                );
                              }).toList(),
                            ),
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

  String _formatTimestamp(DateTime? value) {
    if (value == null) return '—';
    final local = value.toLocal().toIso8601String();
    return local.substring(0, 16).replaceFirst('T', ' ');
  }
}

class _EmptyPanel extends StatelessWidget {
  const _EmptyPanel({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Center(
    child: Text(
      message,
      textDirection: TextDirection.rtl,
      textAlign: TextAlign.center,
      style: Theme.of(context).textTheme.bodyLarge,
    ),
  );
}

class _ErrorPanel extends StatelessWidget {
  const _ErrorPanel({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            message,
            textDirection: TextDirection.rtl,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('إعادة المحاولة'),
          ),
        ],
      ),
    ),
  );
}
