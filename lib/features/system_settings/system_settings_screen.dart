import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/material.dart';
import '../../core/app_theme.dart';
import '../../core/erp_data_table.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../../core/company_logo_storage.dart';
import '../../core/lease_contract_terms.dart';
import '../../core/print_utils.dart';
import '../../database/database_helper.dart';
import '../../core/crypto_utils.dart';
import '../../models/company_info_model.dart';
import '../../providers/auth_provider.dart';
import '../../providers/navigation_provider.dart';
import '../auth/login_screen.dart';

class SystemSettingsScreen extends StatefulWidget {
  const SystemSettingsScreen({super.key});

  @override
  State<SystemSettingsScreen> createState() => _SystemSettingsScreenState();
}

class _SystemSettingsScreenState extends State<SystemSettingsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
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
          tabs: const [
            Tab(text: 'بيانات المنشأة'),
            Tab(text: 'المستخدمين والصلاحيات'),
            Tab(text: 'الصيانة والنسخ الاحتياطي'),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: const [CompanyInfoTab(), UsersTab(), MaintenanceTab()],
          ),
        ),
      ],
    );
  }
}

class CompanyInfoTab extends StatefulWidget {
  const CompanyInfoTab({super.key});

  @override
  State<CompanyInfoTab> createState() => _CompanyInfoTabState();
}

class _CompanyInfoTabState extends State<CompanyInfoTab> {
  final _formKey = GlobalKey<FormState>();
  bool _isLoading = true;
  bool _isSavingCompany = false;
  CompanyInfo? _companyInfo;
  String? _savedLogoPath;
  String? _pendingLogoPath;
  bool _removeLogoRequested = false;

  final _nameArController = TextEditingController();
  final _nameEnController = TextEditingController();
  final _activityController = TextEditingController();
  final _addressController = TextEditingController();

  final _activityArController = TextEditingController();
  final _activityEnController = TextEditingController();
  final _addressArController = TextEditingController();
  final _addressEnController = TextEditingController();
  final _taxNumberController = TextEditingController();
  final _commercialRegisterController = TextEditingController();
  final _poBoxController = TextEditingController();
  final _telephoneController = TextEditingController();
  final _faxController = TextEditingController();
  final _mobileController = TextEditingController();

  String? _selectedCurrency = 'ريال سعودي (SAR)';
  final _logoPathController = TextEditingController();
  final _termsController = TextEditingController();

  final List<String> _currencies = [
    'ريال يمني (YER)',
    'ريال سعودي (SAR)',
    'دولار أمريكي (USD)',
  ];

  @override
  void initState() {
    super.initState();
    _loadCompanyInfo();
  }

  Future<void> _loadCompanyInfo() async {
    final infoMap = await DatabaseHelper.instance.getCompanyInfo();
    if (!mounted) return;
    if (infoMap != null) {
      _companyInfo = CompanyInfo.fromMap(infoMap);
      _nameArController.text = _companyInfo!.nameAr;
      _nameEnController.text = _companyInfo!.nameEn ?? '';
      _activityController.text = _companyInfo!.activity ?? '';
      _addressController.text = _companyInfo!.address ?? '';
      _savedLogoPath = _companyInfo!.logoPath;
      _logoPathController.text = _savedLogoPath ?? '';
      _termsController.text = _companyInfo!.termsConditions?.trim().isNotEmpty ==
              true
          ? _companyInfo!.termsConditions!
          : LeaseContractTerms.defaultText;

      _activityArController.text = _companyInfo!.activityNameAr ?? '';
      _activityEnController.text = _companyInfo!.activityNameEn ?? '';
      _addressArController.text = _companyInfo!.addressAr ?? '';
      _addressEnController.text = _companyInfo!.addressEn ?? '';
      _taxNumberController.text = _companyInfo!.taxNumber ?? '';
      _commercialRegisterController.text =
          _companyInfo!.commercialRegister ?? '';
      _poBoxController.text = _companyInfo!.poBox ?? '';
      _telephoneController.text = _companyInfo!.telephone ?? '';
      _faxController.text = _companyInfo!.fax ?? '';
      _mobileController.text = _companyInfo!.mobile ?? '';

      if (_companyInfo!.defaultCurrency != null &&
          _companyInfo!.defaultCurrency!.isNotEmpty) {
        if (_currencies.contains(_companyInfo!.defaultCurrency)) {
          _selectedCurrency = _companyInfo!.defaultCurrency;
        }
      }
    }
    setState(() {
      _isLoading = false;
    });
  }

  String? get _logoPathError {
    final path = _pendingLogoPath;
    if (path == null || path.isEmpty) return null;
    try {
      final file = File(path);
      if (!file.existsSync()) {
        return 'ملف الشعار المؤقت غير موجود؛ أعد اختياره.';
      }
      if (!CompanyLogoStorage.supportedExtensions.contains(
        p.extension(path).toLowerCase(),
      )) {
        return 'صيغة الشعار يجب أن تكون PNG أو JPG.';
      }
      if (file.lengthSync() > CompanyLogoStorage.maxBytes) {
        return 'حجم ملف الشعار أكبر من 8 ميغابايت.';
      }
    } catch (_) {
      return 'تعذر قراءة ملف الشعار؛ أعد اختياره من جهازك.';
    }
    return null;
  }

  bool get _savedLogoIsMissing =>
      !_removeLogoRequested &&
      _pendingLogoPath == null &&
      _savedLogoPath != null &&
      !File(_savedLogoPath!).existsSync();

  Future<void> _selectLogo() async {
    try {
      final selected = await openFile(
        acceptedTypeGroups: const [
          XTypeGroup(label: 'صور الشعار', extensions: ['png', 'jpg', 'jpeg']),
        ],
      );
      if (selected == null) return;
      final fileName = selected.name.isNotEmpty
          ? selected.name
          : p.basename(selected.path);
      final fileSize = await selected.length();
      if (fileSize > CompanyLogoStorage.maxBytes) {
        _showLogoMessage('حجم ملف الشعار يجب ألا يتجاوز 8 ميغابايت.');
        return;
      }
      final bytes = await selected.readAsBytes();
      final validationError = CompanyLogoStorage.validateBytes(
        fileName,
        bytes,
      );
      if (validationError != null) {
        _showLogoMessage(validationError);
        return;
      }

      final supportDirectory = await getApplicationSupportDirectory();
      final savedFile = await CompanyLogoStorage.saveCandidate(
        fileName: fileName,
        bytes: bytes,
        supportDirectory: supportDirectory.path,
      );
      final previousCandidate = _pendingLogoPath;
      if (!mounted) {
        await CompanyLogoStorage.deleteManagedFile(
          savedFile.path,
          supportDirectory: supportDirectory.path,
        );
        return;
      }
      setState(() {
        _pendingLogoPath = savedFile.path;
        _removeLogoRequested = false;
        _logoPathController.text = savedFile.path;
      });
      if (previousCandidate != null) {
        unawaited(
          CompanyLogoStorage.deleteManagedFile(
            previousCandidate,
            supportDirectory: supportDirectory.path,
          ),
        );
      }
      PrintUtils.clearLogoCache();
      _showLogoMessage(
        'تم التحقق من ملف الشعار؛ اضغط «حفظ التعديلات» لاعتماده.',
      );
    } catch (e) {
      _showLogoMessage('تعذر تحميل الشعار: $e');
    }
  }

  void _removeLogo() {
    final previousCandidate = _pendingLogoPath;
    PrintUtils.clearLogoCache();
    setState(() {
      _pendingLogoPath = null;
      _removeLogoRequested = _savedLogoPath != null;
      _logoPathController.clear();
    });
    if (previousCandidate != null) {
      unawaited(CompanyLogoStorage.deleteManagedFile(previousCandidate));
    }
  }

  void _showLogoMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _saveCompanyInfo() async {
    if (_isSavingCompany) return;
    final logoError = _logoPathError;
    if (logoError != null) {
      _showLogoMessage(logoError);
      return;
    }
    if (!_formKey.currentState!.validate()) return;

    final previousLogoPath = _savedLogoPath;
    final candidatePath = _pendingLogoPath;
    final logoPathToSave = _removeLogoRequested
        ? null
        : (candidatePath ?? previousLogoPath);
    final updatedInfo = CompanyInfo(
      id: _companyInfo?.id ?? 1,
      nameAr: _nameArController.text,
      nameEn: _nameEnController.text,
      activity: _activityController.text,
      address: _addressController.text,
      defaultCurrency: _selectedCurrency,
      logoPath: logoPathToSave,
      termsConditions: _termsController.text,
      activityNameAr: _activityArController.text,
      activityNameEn: _activityEnController.text,
      addressAr: _addressArController.text,
      addressEn: _addressEnController.text,
      taxNumber: _taxNumberController.text,
      commercialRegister: _commercialRegisterController.text,
      poBox: _poBoxController.text,
      telephone: _telephoneController.text,
      fax: _faxController.text,
      mobile: _mobileController.text,
    );

    setState(() => _isSavingCompany = true);
    try {
      await DatabaseHelper.instance.updateCompanyInfo(updatedInfo.toMap());
      // The database now owns the candidate path; disposal must not remove it.
      _savedLogoPath = logoPathToSave;
      _pendingLogoPath = null;
      _removeLogoRequested = false;
      _companyInfo = updatedInfo;
      _logoPathController.text = logoPathToSave ?? '';
      PrintUtils.clearLogoCache();
      if (previousLogoPath != null && previousLogoPath != logoPathToSave) {
        await CompanyLogoStorage.deleteManagedFile(previousLogoPath);
      }
      if (!mounted) return;
      setState(() {});
      final message = _savedLogoIsMissing
          ? 'حُفظت البيانات، لكن ملف الشعار القديم غير موجود؛ أعد رفعه أو أزله.'
          : 'تم حفظ بيانات المنشأة واعتماد الشعار.';
      _showLogoMessage(message);
    } catch (error) {
      if (!mounted && candidatePath != null) {
        unawaited(CompanyLogoStorage.deleteManagedFile(candidatePath));
      }
      if (mounted) _showLogoMessage('تعذر حفظ بيانات المنشأة: $error');
    } finally {
      if (mounted) setState(() => _isSavingCompany = false);
    }
  }

  @override
  void dispose() {
    final candidate = _pendingLogoPath;
    if (candidate != null && !_isSavingCompany) {
      unawaited(CompanyLogoStorage.deleteManagedFile(candidate));
    }
    _nameArController.dispose();
    _nameEnController.dispose();
    _activityController.dispose();
    _addressController.dispose();
    _logoPathController.dispose();
    _termsController.dispose();
    _activityArController.dispose();
    _activityEnController.dispose();
    _addressArController.dispose();
    _addressEnController.dispose();
    _taxNumberController.dispose();
    _commercialRegisterController.dispose();
    _poBoxController.dispose();
    _telephoneController.dispose();
    _faxController.dispose();
    _mobileController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const Center(child: CircularProgressIndicator());
    final selectedLogoPath = _removeLogoRequested
        ? ''
        : (_pendingLogoPath ?? _savedLogoPath ?? '').trim();
    final selectedLogo = selectedLogoPath.isEmpty
        ? null
        : File(selectedLogoPath);
    final hasPreviewLogo = selectedLogo != null && selectedLogo.existsSync();

    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Form(
        key: _formKey,
        child: ListView(
          children: [
            TextFormField(
              controller: _nameArController,
              decoration: const InputDecoration(
                labelText: 'اسم المنشأة (عربي)',
                border: OutlineInputBorder(),
              ),
              validator: (value) =>
                  value == null || value.isEmpty ? 'مطلوب' : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _nameEnController,
              decoration: const InputDecoration(
                labelText: 'اسم المنشأة (إنجليزي)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _activityArController,
                    decoration: const InputDecoration(
                      labelText: 'النشاط (عربي)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: TextFormField(
                    controller: _activityEnController,
                    decoration: const InputDecoration(
                      labelText: 'النشاط (إنجليزي)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _commercialRegisterController,
                    decoration: const InputDecoration(
                      labelText: 'السجل التجاري (C.R)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: TextFormField(
                    controller: _taxNumberController,
                    decoration: const InputDecoration(
                      labelText: 'الرقم الضريبي (VAT)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _addressArController,
                    decoration: const InputDecoration(
                      labelText: 'العنوان (عربي)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: TextFormField(
                    controller: _addressEnController,
                    decoration: const InputDecoration(
                      labelText: 'العنوان (إنجليزي)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _poBoxController,
                    decoration: const InputDecoration(
                      labelText: 'ص.ب (P.O Box)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: TextFormField(
                    controller: _telephoneController,
                    decoration: const InputDecoration(
                      labelText: 'هاتف (Telephone)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: TextFormField(
                    controller: _faxController,
                    decoration: const InputDecoration(
                      labelText: 'فاكس (Fax)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: TextFormField(
                    controller: _mobileController,
                    decoration: const InputDecoration(
                      labelText: 'جوال (Mobile)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              value: _selectedCurrency,
              decoration: const InputDecoration(
                labelText: 'العملة الافتراضية',
                border: OutlineInputBorder(),
              ),
              items: _currencies
                  .map(
                    (curr) => DropdownMenuItem(value: curr, child: Text(curr)),
                  )
                  .toList(),
              onChanged: (val) {
                setState(() {
                  _selectedCurrency = val;
                });
              },
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey.shade400),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Container(
                    width: 96,
                    height: 96,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      border: Border.all(color: Colors.grey.shade300),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: hasPreviewLogo
                        ? ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: Image.file(
                              selectedLogo,
                              width: 94,
                              height: 94,
                              fit: BoxFit.contain,
                              errorBuilder: (_, __, ___) => const Icon(
                                Icons.broken_image_outlined,
                                size: 38,
                                color: Colors.grey,
                              ),
                            ),
                          )
                        : const Icon(
                            Icons.image_outlined,
                            size: 38,
                            color: Colors.grey,
                          ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'شعار المنشأة',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          'اختر ملف الشعار الأصلي؛ سيُدرج مباشرة في ترويسة وتذييل المستندات مع الحفاظ على أبعاده.',
                        ),
                        if (selectedLogoPath.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            'الملف المختار: ${p.basename(selectedLogoPath)}',
                            style: const TextStyle(color: Colors.black54),
                          ),
                        ],
                        if (_logoPathError != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            _logoPathError!,
                            style: const TextStyle(color: Colors.red),
                          ),
                        ],
                        if (_savedLogoIsMissing) ...[
                          const SizedBox(height: 4),
                          const Text(
                            'ملف الشعار المسجل غير موجود؛ يمكنك حفظ بقية البيانات، أو رفع شعار جديد، أو إزالة المرجع.',
                            style: TextStyle(color: Colors.orange),
                          ),
                        ],
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            ElevatedButton.icon(
                              onPressed: _selectLogo,
                              icon: const Icon(Icons.upload_file),
                              label: Text(
                                hasPreviewLogo
                                    ? 'استبدال الشعار'
                                    : 'رفع الشعار',
                              ),
                            ),
                            if (selectedLogoPath.isNotEmpty)
                              OutlinedButton.icon(
                                onPressed: _removeLogo,
                                icon: const Icon(Icons.delete_outline),
                                label: const Text('إزالة الشعار'),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _termsController,
              minLines: 7,
              maxLines: 12,
              textDirection: TextDirection.rtl,
              textAlign: TextAlign.right,
              decoration: const InputDecoration(
                labelText: 'الشروط والأحكام الافتراضية لعقد الإيجار',
                helperText:
                    'اكتب كل شرط في سطر مستقل. العقد المطبوع يقرأ هذه الشروط بعد حفظها هنا.',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 32),
            ElevatedButton(
              onPressed: _isSavingCompany ? null : _saveCompanyInfo,
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.all(16),
              ),
              child: _isSavingCompany
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text(
                      'حفظ التعديلات',
                      style: TextStyle(fontSize: 18),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class UsersTab extends StatefulWidget {
  const UsersTab({super.key});

  @override
  State<UsersTab> createState() => _UsersTabState();
}

class _UsersTabState extends State<UsersTab> {
  List<Map<String, dynamic>> _users = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadUsers();
  }

  Future<void> _loadUsers() async {
    final users = await DatabaseHelper.instance.getAllUsers();
    setState(() {
      _users = users;
      _isLoading = false;
    });
  }

  void _showAddUserDialog() {
    final formKey = GlobalKey<FormState>();
    final fullNameController = TextEditingController();
    final usernameController = TextEditingController();
    final passwordController = TextEditingController();
    final currentRole = Provider.of<AuthProvider>(
      context,
      listen: false,
    ).currentUser?.role;
    String selectedRole = 'DataEntry';

    final List<String> roles = [
      if (currentRole == 'SuperAdmin') 'SuperAdmin',
      'Admin',
      'Accountant',
      'DataEntry',
    ];
    final Map<String, String> roleLabels = {
      'SuperAdmin': 'SuperAdmin (مدير نظام)',
      'Admin': 'Admin (مدير)',
      'Accountant': 'Accountant (محاسب)',
      'DataEntry': 'DataEntry (مدخل بيانات)',
    };

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('إضافة مستخدم جديد'),
              content: Form(
                key: formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextFormField(
                      controller: fullNameController,
                      decoration: const InputDecoration(
                        labelText: 'الاسم الكامل',
                      ),
                      validator: (v) => v!.isEmpty ? 'مطلوب' : null,
                    ),
                    TextFormField(
                      controller: usernameController,
                      decoration: const InputDecoration(
                        labelText: 'اسم المستخدم',
                      ),
                      validator: (v) => v!.isEmpty ? 'مطلوب' : null,
                    ),
                    TextFormField(
                      controller: passwordController,
                      decoration: const InputDecoration(
                        labelText: 'كلمة المرور',
                      ),
                      obscureText: true,
                      validator: (v) => v!.isEmpty ? 'مطلوب' : null,
                    ),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<String>(
                      initialValue: selectedRole,
                      decoration: const InputDecoration(labelText: 'الدور'),
                      items: roles.map((role) {
                        return DropdownMenuItem<String>(
                          value: role,
                          child: Text(roleLabels[role]!),
                        );
                      }).toList(),
                      onChanged: (String? newValue) {
                        if (newValue != null) {
                          setDialogState(() {
                            selectedRole = newValue;
                          });
                        }
                      },
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
                    if (formKey.currentState!.validate()) {
                      if (selectedRole == 'SuperAdmin' &&
                          currentRole != 'SuperAdmin') {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'لا تملك صلاحية إنشاء مدير نظام أعلى.',
                            ),
                          ),
                        );
                        return;
                      }
                      final hashedPassword = CryptoUtils.hashPassword(
                        passwordController.text,
                      );
                      await DatabaseHelper.instance.insertUser({
                        'full_name': fullNameController.text,
                        'username': usernameController.text,
                        'password_hash': hashedPassword,
                        'role': selectedRole,
                      });
                      if (context.mounted) {
                        Navigator.pop(context);
                        _loadUsers();
                      }
                    }
                  },
                  child: const Text('حفظ'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const Center(child: CircularProgressIndicator());

    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'إدارة المستخدمين',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
              ElevatedButton.icon(
                onPressed: _showAddUserDialog,
                icon: const Icon(Icons.add),
                label: const Text('إضافة مستخدم'),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Expanded(
            child: SingleChildScrollView(
              child: ErpDataTable(
                columns: const [
                  DataColumn(label: Text('المعرف')),
                  DataColumn(label: Text('الاسم الكامل')),
                  DataColumn(label: Text('اسم المستخدم')),
                  DataColumn(label: Text('الدور')),
                ],
                rows: _users.map((user) {
                  return DataRow(
                    cells: [
                      DataCell(Text(user['id'].toString())),
                      DataCell(Text(user['full_name'])),
                      DataCell(Text(user['username'])),
                      DataCell(Text(user['role'])),
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

class MaintenanceTab extends StatefulWidget {
  const MaintenanceTab({super.key});

  @override
  State<MaintenanceTab> createState() => _MaintenanceTabState();
}

class _MaintenanceTabState extends State<MaintenanceTab> {
  String _backupPath = '';
  final _backupPathController = TextEditingController();
  final _confirmController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadBackupPath();
  }

  Future<void> _loadBackupPath() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _backupPath = prefs.getString('backup_path') ?? '';
      _backupPathController.text = _backupPath;
    });
  }

  Future<void> _selectBackupFolder() async {
    String? selectedDirectory = await getDirectoryPath();
    if (selectedDirectory != null) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('backup_path', selectedDirectory);
      setState(() {
        _backupPath = selectedDirectory;
        _backupPathController.text = selectedDirectory;
      });
    }
  }

  Future<void> _performBackup() async {
    if (_backupPath.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('الرجاء اختيار مجلد النسخ الاحتياطي أولاً'),
        ),
      );
      return;
    }

    try {
      final timestamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '')
          .replaceAll('-', '')
          .replaceAll('.', '');
      final backupFilePath = p.join(
        _backupPath,
        'aqari_erp_backup_$timestamp.db',
      );
      await DatabaseHelper.instance.backupToFile(backupFilePath);

      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('تم النسخ الاحتياطي بنجاح إلى: $backupFilePath'),
          ),
        );
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('فشل النسخ الاحتياطي: $e')));
    }
  }

  void _showFactoryResetDialog() {
    _confirmController.clear();
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            return AlertDialog(
              title: const Text(
                'تحذير خطير: تهيئة النظام',
                style: TextStyle(
                  color: Colors.red,
                  fontWeight: FontWeight.bold,
                ),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'هذا الإجراء سيمسح جميع البيانات المدخلة في النظام (عقود، مستأجرين، سندات، الخ) وسيعيده كأنه جديد.',
                  ),
                  const SizedBox(height: 16),
                  const Text('لتأكيد الحذف، اكتب كلمة "تأكيد" في الحقل أدناه:'),
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _confirmController,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      hintText: 'تأكيد',
                    ),
                    onChanged: (val) => setStateDialog(() {}),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('إلغاء'),
                ),
                ElevatedButton(
                  onPressed: _confirmController.text == 'تأكيد'
                      ? () async {
                          Navigator.pop(context);
                          await _performFactoryReset();
                        }
                      : null,
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                  child: const Text(
                    'مسح البيانات نهائياً',
                    style: TextStyle(color: Colors.white),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _performFactoryReset() async {
    try {
      await Provider.of<AuthProvider>(context, listen: false).logout();
      await DatabaseHelper.instance.factoryReset();
      if (mounted) {
        Provider.of<NavigationProvider>(context, listen: false).reset();
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const LoginScreen()),
          (_) => false,
        );
      }
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('فشل تهيئة النظام: $e')));
    }
  }

  @override
  void dispose() {
    _backupPathController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'نسخة احتياطية يدوية متحقق منها',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: TextFormField(
                  decoration: const InputDecoration(
                    labelText: 'مسار مجلد النسخ الاحتياطي',
                    border: OutlineInputBorder(),
                  ),
                  controller: _backupPathController,
                  readOnly: true,
                ),
              ),
              const SizedBox(width: 16),
              ElevatedButton.icon(
                onPressed: _selectBackupFolder,
                icon: const Icon(Icons.folder),
                label: const Text('تحديد المجلد'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.all(16),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: _performBackup,
            icon: const Icon(Icons.backup),
            label: const Text('نسخ احتياطي الآن'),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.all(16),
              backgroundColor: Colors.green,
            ),
          ),
          const SizedBox(height: 48),
          const Divider(),
          const SizedBox(height: 24),
          const Text(
            'تهيئة وتصفير النظام (Factory Reset)',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: Colors.red,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'احذر: هذه العملية ستمسح جميع قواعد البيانات الخاصة بالمؤسسة.',
          ),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: _showFactoryResetDialog,
            icon: const Icon(Icons.warning, color: Colors.white),
            label: const Text(
              'تصفير النظام بالكامل',
              style: TextStyle(color: Colors.white),
            ),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.all(16),
              backgroundColor: Colors.red,
            ),
          ),
        ],
      ),
    );
  }
}
