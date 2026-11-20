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
  const LookupTab({
    super.key,
    required this.config,
    required this.displayFields,
    this.dataLoader,
  });

  @override
  State<LookupTab> createState() => _LookupTabState();
}

class _LookupTabState extends State<LookupTab> {
  List<Map<String, dynamic>> _data = [];
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
        return (row[field]?.toString() ?? '').toLowerCase().contains(query);
      });
    }).toList();
  }

  Future<void> _loadData() async {
    final loader = widget.dataLoader;
    final data = loader == null
        ? await DatabaseHelper.instance.getLookupData(widget.config.tableName)
        : await loader();
    if (!mounted) return;
    setState(() {
      _data = data;
      _isLoading = false;
    });
  }

  void _showAddEditDialog([Map<String, dynamic>? item]) {
    final formKey = GlobalKey<FormState>();
    final Map<String, TextEditingController> controllers = {};

    for (var field in widget.config.fields) {
      controllers[field] = TextEditingController(
        text: item != null ? item[field]?.toString() : '',
      );
    }

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(
            item == null
                ? 'إضافة ${widget.config.title}'
                : 'تعديل ${widget.config.title}',
          ),
          content: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: widget.config.fields.map((field) {
                return TextFormField(
                  controller: controllers[field],
                  decoration: InputDecoration(labelText: field),
                  validator: (v) => v!.isEmpty ? 'مطلوب' : null,
                );
              }).toList(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('إلغاء'),
            ),
            ElevatedButton(
              onPressed: () async {
                if (formKey.currentState!.validate()) {
                  final Map<String, dynamic> data = {};
                  for (var field in widget.config.fields) {
                    data[field] = controllers[field]!.text;
                  }

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
                    _loadData();
                  }
                }
              },
              child: const Text('حفظ'),
            ),
          ],
        );
      },
    );
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
                                Text(row[field]?.toString() ?? ''),
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
                                    onPressed: PermissionRuntime.allows(
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
                                    onPressed: PermissionRuntime.allows(
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
