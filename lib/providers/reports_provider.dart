import 'package:flutter/material.dart';
import '../database/database_helper.dart';
import '../models/account_statement_report_model.dart';
import '../models/owner_statement_account_model.dart';
import '../models/tenant_statement_account_model.dart';

class ReportsProvider with ChangeNotifier {
  ReportsProvider({
    Future<List<Map<String, dynamic>>> Function()?
    propertyInquiryPropertiesLoader,
    Future<List<Map<String, dynamic>>> Function(int propertyId)?
    propertyInquiryUnitsLoader,
    Future<AccountStatementReport> Function(
      int accountId,
      String startDate,
      String endDate,
    )?
    accountStatementLoader,
    Future<List<Map<String, dynamic>>> Function()?
    tenantStatementAccountsLoader,
    Future<AccountStatementReport> Function(
      int tenantId,
      int accountId,
      String startDate,
      String endDate,
    )?
    tenantStatementLoader,
    Future<List<Map<String, dynamic>>> Function()? ownerStatementAccountsLoader,
    Future<AccountStatementReport> Function(
      int ownerId,
      int accountId,
      String startDate,
      String endDate,
    )?
    ownerStatementLoader,
  }) : _propertyInquiryPropertiesLoader = propertyInquiryPropertiesLoader,
       _propertyInquiryUnitsLoader = propertyInquiryUnitsLoader,
       _accountStatementLoader = accountStatementLoader,
       _tenantStatementAccountsLoader = tenantStatementAccountsLoader,
       _tenantStatementLoader = tenantStatementLoader,
       _ownerStatementAccountsLoader = ownerStatementAccountsLoader,
       _ownerStatementLoader = ownerStatementLoader;

  final Future<List<Map<String, dynamic>>> Function()?
  _propertyInquiryPropertiesLoader;
  final Future<List<Map<String, dynamic>>> Function(int propertyId)?
  _propertyInquiryUnitsLoader;
  final Future<AccountStatementReport> Function(
    int accountId,
    String startDate,
    String endDate,
  )?
  _accountStatementLoader;
  final Future<List<Map<String, dynamic>>> Function()?
  _tenantStatementAccountsLoader;
  final Future<AccountStatementReport> Function(
    int tenantId,
    int accountId,
    String startDate,
    String endDate,
  )?
  _tenantStatementLoader;
  final Future<List<Map<String, dynamic>>> Function()?
  _ownerStatementAccountsLoader;
  final Future<AccountStatementReport> Function(
    int ownerId,
    int accountId,
    String startDate,
    String endDate,
  )?
  _ownerStatementLoader;

  List<Map<String, dynamic>> _searchResults = [];
  List<Map<String, dynamic>> _occupancyStats = [];
  AccountStatementReport? _accountStatementReport;
  AccountStatementReport? _tenantStatementReport;
  AccountStatementReport? _ownerStatementReport;
  List<TenantStatementAccount> _tenantStatementAccounts = [];
  List<OwnerStatementAccount> _ownerStatementAccounts = [];
  List<Map<String, dynamic>> _dueInstallments = [];
  List<Map<String, dynamic>> _expiringContracts = [];
  List<Map<String, dynamic>> _propertyInquiryProperties = [];
  List<Map<String, dynamic>> _propertyInquiryUnits = [];
  int _searchGeneration = 0;
  int _occupancyGeneration = 0;
  int _statementGeneration = 0;
  int _tenantStatementGeneration = 0;
  int _tenantAccountsGeneration = 0;
  int _ownerStatementGeneration = 0;
  int _ownerAccountsGeneration = 0;
  int _alertsGeneration = 0;
  int _propertyInquiryGeneration = 0;
  int? _authorizedUserId;
  bool? _hadReportsAccess;
  int? _selectedInquiryPropertyId;
  DateTime? _propertyInquiryAsOf;
  bool _isPropertyInquiryLoading = false;
  bool _propertyInquiryPropertiesLoaded = false;
  bool _propertyInquiryUnitsLoaded = false;
  String? _propertyInquiryErrorMessage;
  String? _errorMessage;
  String? _statementErrorMessage;
  String? _tenantStatementErrorMessage;
  String? _tenantAccountsErrorMessage;
  String? _ownerStatementErrorMessage;
  String? _ownerAccountsErrorMessage;

  bool _isLoading = false;
  bool _isStatementLoading = false;
  bool _isTenantStatementLoading = false;
  bool _isTenantAccountsLoading = false;
  bool _tenantStatementAccountsLoaded = false;
  bool _isOwnerStatementLoading = false;
  bool _isOwnerAccountsLoading = false;
  bool _ownerStatementAccountsLoaded = false;

  List<Map<String, dynamic>> get searchResults => _searchResults;
  List<Map<String, dynamic>> get occupancyStats => _occupancyStats;
  AccountStatementReport? get accountStatementReport => _accountStatementReport;
  AccountStatementReport? get tenantStatementReport => _tenantStatementReport;
  AccountStatementReport? get ownerStatementReport => _ownerStatementReport;
  List<TenantStatementAccount> get tenantStatementAccounts =>
      List.unmodifiable(_tenantStatementAccounts);
  bool get isTenantStatementLoading => _isTenantStatementLoading;
  bool get isTenantAccountsLoading => _isTenantAccountsLoading;
  bool get tenantStatementAccountsLoaded => _tenantStatementAccountsLoaded;
  List<OwnerStatementAccount> get ownerStatementAccounts =>
      List.unmodifiable(_ownerStatementAccounts);
  bool get isOwnerStatementLoading => _isOwnerStatementLoading;
  bool get isOwnerAccountsLoading => _isOwnerAccountsLoading;
  bool get ownerStatementAccountsLoaded => _ownerStatementAccountsLoaded;
  String? get ownerStatementErrorMessage => _ownerStatementErrorMessage;
  String? get ownerAccountsErrorMessage => _ownerAccountsErrorMessage;
  String? get tenantStatementErrorMessage => _tenantStatementErrorMessage;
  String? get tenantAccountsErrorMessage => _tenantAccountsErrorMessage;
  List<Map<String, dynamic>> get accountStatement =>
      _accountStatementReport?.lines
          .map(
            (line) => {
              'date': line.date,
              'voucher_no': line.journalEntryId,
              'description': line.description,
              'debit': line.debit,
              'credit': line.credit,
              'running_balance': line.runningBalance,
            },
          )
          .toList(growable: false) ??
      const [];
  List<Map<String, dynamic>> get dueInstallments => _dueInstallments;
  List<Map<String, dynamic>> get expiringContracts => _expiringContracts;
  List<Map<String, dynamic>> get propertyInquiryProperties =>
      _propertyInquiryProperties;
  List<Map<String, dynamic>> get propertyInquiryUnits => _propertyInquiryUnits;
  int? get selectedInquiryPropertyId => _selectedInquiryPropertyId;
  DateTime? get propertyInquiryAsOf => _propertyInquiryAsOf;
  bool get isPropertyInquiryLoading => _isPropertyInquiryLoading;
  bool get propertyInquiryPropertiesLoaded => _propertyInquiryPropertiesLoaded;
  bool get propertyInquiryUnitsLoaded => _propertyInquiryUnitsLoaded;
  String? get propertyInquiryErrorMessage => _propertyInquiryErrorMessage;
  bool get isLoading => _isLoading;
  bool get isStatementLoading => _isStatementLoading;
  double get accountOpeningBalance =>
      _accountStatementReport?.openingBalance ?? 0;
  String? get errorMessage => _errorMessage;
  String? get statementErrorMessage => _statementErrorMessage;

  /// Called by the app-level auth proxy to prevent report data from surviving
  /// an authenticated-user switch or loss of reports.view. A restored grant
  /// must not invalidate a fresh account-list request started by the screen.
  void syncAuthorization({required int? userId, required bool canViewReports}) {
    final switchedAuthenticatedUser =
        _authorizedUserId != null && _authorizedUserId != userId;
    final lostReportsAccess = _hadReportsAccess == true && !canViewReports;
    if (switchedAuthenticatedUser || lostReportsAccess) {
      clearReportResults(notify: false);
      clearSensitiveAlerts(notify: false);
    }
    _authorizedUserId = userId;
    _hadReportsAccess = canViewReports;
  }

  void clearSensitiveAlerts({bool notify = true}) {
    _alertsGeneration++;
    _dueInstallments = [];
    _expiringContracts = [];
    _isLoading = false;
    if (notify) notifyListeners();
  }

  void clearReportResults({bool notify = true}) {
    _searchGeneration++;
    _occupancyGeneration++;
    _statementGeneration++;
    _tenantStatementGeneration++;
    _tenantAccountsGeneration++;
    _ownerStatementGeneration++;
    _ownerAccountsGeneration++;
    _propertyInquiryGeneration++;
    _searchResults = [];
    _occupancyStats = [];
    _accountStatementReport = null;
    _tenantStatementReport = null;
    _ownerStatementReport = null;
    _tenantStatementAccounts = [];
    _ownerStatementAccounts = [];
    _isTenantStatementLoading = false;
    _isTenantAccountsLoading = false;
    _tenantStatementAccountsLoaded = false;
    _isOwnerStatementLoading = false;
    _isOwnerAccountsLoading = false;
    _ownerStatementAccountsLoaded = false;
    _isStatementLoading = false;
    _statementErrorMessage = null;
    _tenantStatementErrorMessage = null;
    _tenantAccountsErrorMessage = null;
    _ownerStatementErrorMessage = null;
    _ownerAccountsErrorMessage = null;
    _clearPropertyInquiry();
    _isLoading = false;
    _errorMessage = null;
    if (notify) notifyListeners();
  }

  void _clearPropertyInquiry() {
    _propertyInquiryProperties = [];
    _propertyInquiryUnits = [];
    _selectedInquiryPropertyId = null;
    _propertyInquiryAsOf = null;
    _isPropertyInquiryLoading = false;
    _propertyInquiryPropertiesLoaded = false;
    _propertyInquiryUnitsLoaded = false;
    _propertyInquiryErrorMessage = null;
  }

  Future<void> loadPropertyInquiryProperties() async {
    final generation = ++_propertyInquiryGeneration;
    _isPropertyInquiryLoading = true;
    _propertyInquiryErrorMessage = null;
    _propertyInquiryPropertiesLoaded = false;
    _propertyInquiryUnits = [];
    _selectedInquiryPropertyId = null;
    _propertyInquiryAsOf = null;
    notifyListeners();

    try {
      final properties =
          await (_propertyInquiryPropertiesLoader ??
              DatabaseHelper.instance.getPropertyUnitInquiryProperties)();
      if (generation == _propertyInquiryGeneration) {
        _propertyInquiryProperties = properties;
        _propertyInquiryPropertiesLoaded = true;
      }
    } catch (error) {
      if (generation == _propertyInquiryGeneration) {
        _propertyInquiryProperties = [];
        _propertyInquiryErrorMessage = 'تعذر تحميل قائمة العقارات: $error';
      }
    } finally {
      if (generation == _propertyInquiryGeneration) {
        _isPropertyInquiryLoading = false;
        notifyListeners();
      }
    }
  }

  Future<void> loadPropertyInquiryUnits(int propertyId) async {
    if (propertyId <= 0) throw ArgumentError('العقار المحدد غير صالح');
    final isKnownProperty = _propertyInquiryProperties.any(
      (property) => property['id'] == propertyId,
    );
    if (!isKnownProperty) throw StateError('العقار المحدد غير موجود');

    final generation = ++_propertyInquiryGeneration;
    _selectedInquiryPropertyId = propertyId;
    _propertyInquiryUnits = [];
    _propertyInquiryAsOf = null;
    _propertyInquiryUnitsLoaded = false;
    _isPropertyInquiryLoading = true;
    _propertyInquiryErrorMessage = null;
    notifyListeners();

    try {
      final units =
          await (_propertyInquiryUnitsLoader ??
              DatabaseHelper.instance.getPropertyUnitInquiryUnits)(propertyId);
      if (generation == _propertyInquiryGeneration &&
          _selectedInquiryPropertyId == propertyId) {
        _propertyInquiryUnits = units;
        _propertyInquiryAsOf = DateTime.now();
        _propertyInquiryUnitsLoaded = true;
      }
    } catch (error) {
      if (generation == _propertyInquiryGeneration) {
        _propertyInquiryUnits = [];
        _propertyInquiryErrorMessage = 'تعذر تحميل وحدات العقار: $error';
      }
    } finally {
      if (generation == _propertyInquiryGeneration) {
        _isPropertyInquiryLoading = false;
        notifyListeners();
      }
    }
  }

  Future<void> search(String query) async {
    final generation = ++_searchGeneration;
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();
    try {
      final results = query.isNotEmpty
          ? await DatabaseHelper.instance.searchTenantsAndContracts(query)
          : <Map<String, dynamic>>[];
      if (generation == _searchGeneration) _searchResults = results;
    } catch (e) {
      if (generation == _searchGeneration) {
        _errorMessage = 'تعذر تنفيذ الاستعلام: $e';
      }
    } finally {
      if (generation == _searchGeneration) {
        _isLoading = false;
        notifyListeners();
      }
    }
  }

  Future<void> loadOccupancyStats() async {
    final generation = ++_occupancyGeneration;
    _isLoading = true;
    notifyListeners();

    try {
      final stats = await DatabaseHelper.instance.getUnitOccupancyStats();
      if (generation == _occupancyGeneration) {
        _occupancyStats = stats;
        _errorMessage = null;
      }
    } catch (e) {
      if (generation == _occupancyGeneration) {
        _errorMessage = 'تعذر تحميل تقرير الإشغال: $e';
      }
    } finally {
      if (generation == _occupancyGeneration) {
        _isLoading = false;
        notifyListeners();
      }
    }
  }

  Future<void> loadAccountStatement(
    int accountId,
    String startDate,
    String endDate,
  ) async {
    final generation = ++_statementGeneration;
    _accountStatementReport = null;
    _isStatementLoading = true;
    _statementErrorMessage = null;
    notifyListeners();

    try {
      final loader = _accountStatementLoader;
      final report = loader == null
          ? await DatabaseHelper.instance.getLedgerAccountStatement(
              accountId: accountId,
              startDate: startDate,
              endDate: endDate,
            )
          : await loader(accountId, startDate, endDate);
      if (generation == _statementGeneration) {
        _accountStatementReport = report;
        _statementErrorMessage = null;
      }
    } catch (e) {
      if (generation == _statementGeneration) {
        _accountStatementReport = null;
        _statementErrorMessage = 'تعذر تحميل كشف الحساب: $e';
      }
    } finally {
      if (generation == _statementGeneration) {
        _isStatementLoading = false;
        notifyListeners();
      }
    }
  }

  void clearAccountStatement({bool notify = true}) {
    _statementGeneration++;
    _accountStatementReport = null;
    _isStatementLoading = false;
    _statementErrorMessage = null;
    if (notify) notifyListeners();
  }

  Future<void> loadTenantStatementAccounts() async {
    final generation = ++_tenantAccountsGeneration;
    _tenantStatementGeneration++;
    _tenantStatementReport = null;
    _isTenantStatementLoading = false;
    _tenantStatementErrorMessage = null;
    _tenantAccountsErrorMessage = null;
    _isTenantAccountsLoading = true;
    _tenantStatementAccountsLoaded = false;
    _tenantStatementAccounts = [];
    notifyListeners();

    try {
      final rows =
          await (_tenantStatementAccountsLoader ??
              DatabaseHelper.instance.getTenantStatementAccounts)();
      if (generation == _tenantAccountsGeneration) {
        _tenantStatementAccounts = rows
            .map(TenantStatementAccount.fromMap)
            .toList(growable: false);
        _tenantStatementAccountsLoaded = true;
      }
    } catch (error) {
      if (generation == _tenantAccountsGeneration) {
        _tenantStatementAccounts = [];
        _tenantAccountsErrorMessage = 'تعذر تحميل قائمة المستأجرين: $error';
      }
    } finally {
      if (generation == _tenantAccountsGeneration) {
        _isTenantAccountsLoading = false;
        notifyListeners();
      }
    }
  }

  Future<void> loadTenantStatement(
    int tenantId,
    String startDate,
    String endDate,
  ) async {
    final selectedTenants = _tenantStatementAccounts.where(
      (tenant) => tenant.tenantId == tenantId,
    );
    if (selectedTenants.isEmpty || !selectedTenants.single.isReportable) {
      _tenantStatementReport = null;
      _tenantStatementErrorMessage = 'المستأجر لا يرتبط بحساب ذمم تفصيلي صالح';
      notifyListeners();
      return;
    }
    final accountId = selectedTenants.single.accountId!;
    final generation = ++_tenantStatementGeneration;
    _tenantStatementReport = null;
    _tenantStatementErrorMessage = null;
    _isTenantStatementLoading = true;
    notifyListeners();

    try {
      final loader = _tenantStatementLoader;
      final report = loader == null
          ? await DatabaseHelper.instance.getLedgerAccountStatement(
              accountId: accountId,
              expectedTenantId: tenantId,
              startDate: startDate,
              endDate: endDate,
            )
          : await loader(tenantId, accountId, startDate, endDate);
      if (generation == _tenantStatementGeneration) {
        _tenantStatementReport = report;
        _tenantStatementErrorMessage = null;
      }
    } catch (error) {
      if (generation == _tenantStatementGeneration) {
        _tenantStatementReport = null;
        _tenantStatementErrorMessage = 'تعذر تحميل كشف المستأجر: $error';
      }
    } finally {
      if (generation == _tenantStatementGeneration) {
        _isTenantStatementLoading = false;
        notifyListeners();
      }
    }
  }

  void clearTenantStatementReport({bool notify = true}) {
    _tenantStatementGeneration++;
    _tenantStatementReport = null;
    _isTenantStatementLoading = false;
    _tenantStatementErrorMessage = null;
    if (notify) notifyListeners();
  }

  void clearTenantStatement({bool notify = true}) {
    _tenantStatementGeneration++;
    _tenantAccountsGeneration++;
    _tenantStatementReport = null;
    _tenantStatementAccounts = [];
    _isTenantStatementLoading = false;
    _isTenantAccountsLoading = false;
    _tenantStatementAccountsLoaded = false;
    _tenantStatementErrorMessage = null;
    _tenantAccountsErrorMessage = null;
    if (notify) notifyListeners();
  }

  Future<void> loadOwnerStatementAccounts() async {
    final generation = ++_ownerAccountsGeneration;
    _ownerStatementGeneration++;
    _ownerStatementReport = null;
    _isOwnerStatementLoading = false;
    _ownerStatementErrorMessage = null;
    _ownerAccountsErrorMessage = null;
    _isOwnerAccountsLoading = true;
    _ownerStatementAccountsLoaded = false;
    _ownerStatementAccounts = [];
    notifyListeners();

    try {
      final rows =
          await (_ownerStatementAccountsLoader ??
              DatabaseHelper.instance.getOwnerStatementAccounts)();
      if (generation == _ownerAccountsGeneration) {
        _ownerStatementAccounts = rows
            .map(OwnerStatementAccount.fromMap)
            .toList(growable: false);
        _ownerStatementAccountsLoaded = true;
      }
    } catch (error) {
      if (generation == _ownerAccountsGeneration) {
        _ownerStatementAccounts = [];
        _ownerAccountsErrorMessage = 'تعذر تحميل قائمة الملاك: $error';
      }
    } finally {
      if (generation == _ownerAccountsGeneration) {
        _isOwnerAccountsLoading = false;
        notifyListeners();
      }
    }
  }

  Future<void> loadOwnerStatement(
    int ownerId,
    String startDate,
    String endDate,
  ) async {
    final selectedOwners = _ownerStatementAccounts.where(
      (owner) => owner.ownerId == ownerId,
    );
    if (selectedOwners.isEmpty || !selectedOwners.single.isReportable) {
      _ownerStatementReport = null;
      _ownerStatementErrorMessage =
          'المالك لا يرتبط بحساب التزامات تفصيلي صالح';
      notifyListeners();
      return;
    }
    final accountId = selectedOwners.single.accountId!;
    final generation = ++_ownerStatementGeneration;
    _ownerStatementReport = null;
    _ownerStatementErrorMessage = null;
    _isOwnerStatementLoading = true;
    notifyListeners();

    try {
      final loader = _ownerStatementLoader;
      final report = loader == null
          ? await DatabaseHelper.instance.getLedgerAccountStatement(
              accountId: accountId,
              expectedOwnerId: ownerId,
              startDate: startDate,
              endDate: endDate,
            )
          : await loader(ownerId, accountId, startDate, endDate);
      if (generation == _ownerStatementGeneration) {
        _ownerStatementReport = report;
        _ownerStatementErrorMessage = null;
      }
    } catch (error) {
      if (generation == _ownerStatementGeneration) {
        _ownerStatementReport = null;
        _ownerStatementErrorMessage = 'تعذر تحميل كشف المالك: $error';
      }
    } finally {
      if (generation == _ownerStatementGeneration) {
        _isOwnerStatementLoading = false;
        notifyListeners();
      }
    }
  }

  void clearOwnerStatementReport({bool notify = true}) {
    _ownerStatementGeneration++;
    _ownerStatementReport = null;
    _isOwnerStatementLoading = false;
    _ownerStatementErrorMessage = null;
    if (notify) notifyListeners();
  }

  void clearOwnerStatement({bool notify = true}) {
    _ownerStatementGeneration++;
    _ownerAccountsGeneration++;
    _ownerStatementReport = null;
    _ownerStatementAccounts = [];
    _isOwnerStatementLoading = false;
    _isOwnerAccountsLoading = false;
    _ownerStatementAccountsLoaded = false;
    _ownerStatementErrorMessage = null;
    _ownerAccountsErrorMessage = null;
    if (notify) notifyListeners();
  }

  Future<void> loadAlertsDashboard() async {
    final generation = ++_alertsGeneration;
    _dueInstallments = [];
    _expiringContracts = [];
    _isLoading = true;
    notifyListeners();

    try {
      final dueInstallments = await DatabaseHelper.instance.getDueInstallments(
        3,
      );
      final expiringContracts = await DatabaseHelper.instance
          .getExpiringContracts(30);
      if (generation == _alertsGeneration) {
        _dueInstallments = dueInstallments;
        _expiringContracts = expiringContracts;
        _errorMessage = null;
      }
    } catch (e) {
      if (generation == _alertsGeneration) {
        _errorMessage = 'تعذر تحميل التنبيهات: $e';
      }
    } finally {
      if (generation == _alertsGeneration) {
        _isLoading = false;
        notifyListeners();
      }
    }
  }
}
