import 'package:flutter/material.dart';
import '../../core/app_theme.dart';
import '../../core/erp_data_table.dart';
import '../../core/permission_policy.dart';
import '../../database/database_helper.dart';

class LookupsScreen extends StatefulWidget {
  const LookupsScreen({super.key});

  @override
  State<LookupsScreen> createState() => _LookupsScreenState();
}

class _LookupsScreenState extends State<LookupsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  final List<LookupConfig> lookupConfigs = [
    LookupConfig('المدن', 'cities', ['name']),
    LookupConfig('الجنسيات', 'nationalities', ['name']),
    LookupConfig('البنوك', 'banks', ['name', 'account_id']),
    LookupConfig('أنواع العقارات', 'property_types', ['name']),
    LookupConfig('أنواع العيون', 'unit_types', ['name']),
    LookupConfig('مراكز التكلفة', 'cost_centers', [
      'name',
    ]), // Removed 'code' from fields list for input
  ];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: lookupConfigs.length, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TabBar(
          controller: _tabController,
          labelColor: AppPalette.navy,
          unselectedLabelColor: Colors.grey,
          isScrollable: true,
          tabs: lookupConfigs.map((config) => Tab(text: config.title)).toList(),
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: lookupConfigs.map((config) {
              // Determine display fields
              List<String> displayFields = List.from(config.fields);
              if (config.tableName == 'cost_centers') {
                displayFields.insert(
                  0,
                  'code',
                ); // Always show 'code' first in the table
              }
              return LookupTab(config: config, displayFields: displayFields);
            }).toList(),
          ),
        ),
      ],
    );
  }
}

class LookupConfig {
  final String title;
  final String tableName;
  final List<String> fields;

  LookupConfig(this.title, this.tableName, this.fields);
}

class LookupTab extends StatefulWidget {
  final LookupConfig config;
  final List<String> displayFields;
  @visibleForTesting
  final Future<List<Map<String, dynamic>>> Function()? dataLoader;
  @visibleForTesting
  final Future<List<Map<String, dynamic>>> Function()? bankAccountLoader;
  const LookupTab({
    super.key,
    required this.config,
    required this.displayFields,
    this.dataLoader,
    this.bankAccountLoader,
  });

  @override
  State<LookupTab> createState() => _LookupTabState();
}

class _LookupTabState extends State<LookupTab> {
  List<Map<String, dynamic>> _data = [];
  List<Map<String, dynamic>> _bankAccounts = [];
  bool _isLoading = true;
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    _loadData();
  }

  @override
  void dispose() {
    _searchController
      ..removeListener(_onSearchChanged)
      ..dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    if (mounted) setState(() {});
  }

  List<Map<String, dynamic>> get _filteredData {
    final query = _searchController.text.trim().toLowerCase();
    if (query.isEmpty) return _data;
    return _data.where((row) {
      return ['id', ...widget.displayFields].any((field) {
        return _displayFieldValue(row, field).toLowerCase().contains(query);
      });
    }).toList();
  }

  String _displayFieldValue(Map<String, dynamic> row, String field) {
    if (widget.config.tableName == 'banks' && field == 'account_id') {
      final rawId = row[field];
      if (rawId == null) return 'غير مرتبط';
      final id = rawId is num ? rawId.toInt() : int.tryParse(rawId.toString());
      for (final account in _bankAccounts) {
        if ((account['id'] as num).toInt() == id) {
          return '${account['code']} — ${account['name']}';
        }
      }
      return 'حساب غير صالح (#$rawId)';
    }
    return row[field]?.toString() ?? '';
  }

  Future<void> _loadData() async {
    final loader = widget.dataLoader;
    final data = loader == null
        ? await DatabaseHelper.instance.getLookupData(widget.config.tableName)
        : await loader();
    final bankAccounts = widget.config.tableName == 'banks'
        ? await (widget.bankAccountLoader == null
              ? DatabaseHelper.instance.getBankLookupAccounts()
              : widget.bankAccountLoader!())
        : <Map<String, dynamic>>[];
    if (!mounted) return;
    setState(() {
      _data = data;
      _bankAccounts = bankAccounts;
      _isLoading = false;
    });
  }

  Future<void> _showAddEditDialog([Map<String, dynamic>? item]) async {
    final isBank = widget.config.tableName == 'banks';
    final bankAccounts = isBank
        ? await (widget.bankAccountLoader == null
              ? DatabaseHelper.instance.getBankLookupAccounts()
              : widget.bankAccountLoader!())
        : <Map<String, dynamic>>[];
    if (!mounted) return;

    final formKey = GlobalKey<FormState>();
    final Map<String, TextEditingController> controllers = {};
    final rawInitialAccountId = item?['account_id'];
    final initialBankAccountId = rawInitialAccountId is num
        ? rawInitialAccountId.toInt()
        : int.tryParse(rawInitialAccountId?.toString() ?? '');
    var selectedBankAccountId =
        bankAccounts.any(
          (account) => (account['id'] as num).toInt() == initialBankAccountId,
        )
        ? initialBankAccountId
        : null;

    for (var field in widget.config.fields) {
      if (isBank && field == 'account_id') continue;
      controllers[field] = TextEditingController(
        text: item != null ? item[field]?.toString() : '',
      );
    }

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(
            item == null
                ? 'إضافة ${widget.config.title}'
                : 'تعديل ${widget.config.title}',
          ),
          content: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final field in widget.config.fields)
                  if (isBank && field == 'account_id') ...[
                    if (initialBankAccountId != null &&
                        selectedBankAccountId == null)
                      const Padding(
                        padding: EdgeInsets.only(bottom: 8),
                        child: Text(
                          'الحساب المرتبط حاليًا غير صالح. اختر حسابًا تفصيليًا من النقدية والبنوك لإصلاح الربط.',
                          style: TextStyle(color: Colors.deepOrange),
                        ),
                      ),
                    DropdownButtonFormField<int>(
                      initialValue: selectedBankAccountId,
                      items: bankAccounts
                          .map(
                            (account) => DropdownMenuItem<int>(
                              value: (account['id'] as num).toInt(),
                              child: Text(
                                '${account['code']} — ${account['name']}',
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (value) =>
                          setDialogState(() => selectedBankAccountId = value),
                      decoration: const InputDecoration(
                        labelText: 'الحساب البنكي المحاسبي',
                        helperText:
                            'اختر حسابًا تفصيليًا تحت النقدية والبنوك (11)',
                      ),
                      validator: (value) =>
                          value == null ? 'اختر حسابًا بنكيًا صالحًا' : null,
                    ),
                  ] else
                    TextFormField(
                      controller: controllers[field],
                      decoration: InputDecoration(labelText: field),
                      validator: (value) =>
                          value?.trim().isEmpty ?? true ? 'مطلوب' : null,
                    ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('إلغاء'),
            ),
            ElevatedButton(
              onPressed: () async {
                if (!(formKey.currentState?.validate() ?? false)) return;
                final data = <String, dynamic>{
                  for (final field in widget.config.fields)
                    if (!(isBank && field == 'account_id'))
                      field: controllers[field]!.text.trim(),
                };
                if (isBank) data['account_id'] = selectedBankAccountId;
                try {
                  if (item == null) {
                    await DatabaseHelper.instance.insertLookupData(
                      widget.config.tableName,
                      data,
                    );
                  } else {
                    data['id'] = item['id'];
                    await DatabaseHelper.instance.updateLookupData(
                      widget.config.tableName,
                      data,
                    );
                  }

                  if (context.mounted) {
                    Navigator.pop(context);
                    await _loadData();
                  }
                } catch (error) {
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('تعذر حفظ البيانات: $error')),
                  );
                }
              },
              child: const Text('حفظ'),
            ),
          ],
        ),
      ),
    );
    for (final controller in controllers.values) {
      controller.dispose();
    }
  }

  void _deleteItem(int id) async {
    await DatabaseHelper.instance.deleteLookupData(widget.config.tableName, id);
    _loadData();
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const Center(child: CircularProgressIndicator());

    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 16,
            runSpacing: 12,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 360,
                child: TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    labelText: 'بحث في ${widget.config.title}',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _searchController.text.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'مسح البحث',
                            onPressed: _searchController.clear,
                            icon: const Icon(Icons.clear),
                          ),
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              ElevatedButton.icon(
                onPressed:
                    PermissionRuntime.allows('lookups', AppPermissionAction.add)
                    ? () => _showAddEditDialog()
                    : null,
                icon: const Icon(Icons.add),
                label: Text('إضافة ${widget.config.title}'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: Text('النتائج: ${_filteredData.length} من ${_data.length}'),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: _filteredData.isEmpty
                ? Center(
                    child: Text(
                      _data.isEmpty
                          ? 'لا توجد بيانات في ${widget.config.title} بعد'
                          : 'لا توجد نتائج مطابقة لعبارة البحث',
                    ),
                  )
                : SingleChildScrollView(
                    child: ErpDataTable(
                      columns: [
                        const DataColumn(label: Text('المعرف')),
                        ...widget.displayFields.map(
                          (field) => DataColumn(label: Text(field)),
                        ),
                        const DataColumn(label: Text('الإجراءات')),
                      ],
                      rows: _filteredData.map((row) {
                        return DataRow(
                          cells: [
                            DataCell(Text(row['id'].toString())),
                            ...widget.displayFields.map(
                              (field) => DataCell(
                                Text(_displayFieldValue(row, field)),
                              ),
                            ),
                            DataCell(
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    icon: const Icon(
                                      Icons.edit,
                                      color: AppPalette.navy,
                                    ),
                                    onPressed:
                                        PermissionRuntime.allows(
                                          'lookups',
                                          AppPermissionAction.edit,
                                        )
                                        ? () => _showAddEditDialog(row)
                                        : null,
                                  ),
                                  IconButton(
                                    icon: const Icon(
                                      Icons.delete,
                                      color: Colors.red,
                                    ),
                                    onPressed:
                                        PermissionRuntime.allows(
                                          'lookups',
                                          AppPermissionAction.delete,
                                        )
                                        ? () => _deleteItem(row['id'])
                                        : null,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        );
                      }).toList(),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
