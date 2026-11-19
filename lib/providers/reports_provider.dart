import 'package:flutter/material.dart';
import '../database/database_helper.dart';
import '../models/account_statement_report_model.dart';

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
  }) : _propertyInquiryPropertiesLoader = propertyInquiryPropertiesLoader,
       _propertyInquiryUnitsLoader = propertyInquiryUnitsLoader,
       _accountStatementLoader = accountStatementLoader;

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

  List<Map<String, dynamic>> _searchResults = [];
  List<Map<String, dynamic>> _occupancyStats = [];
  AccountStatementReport? _accountStatementReport;
  List<Map<String, dynamic>> _dueInstallments = [];
  List<Map<String, dynamic>> _expiringContracts = [];
  List<Map<String, dynamic>> _propertyInquiryProperties = [];
  List<Map<String, dynamic>> _propertyInquiryUnits = [];
  int _searchGeneration = 0;
  int _occupancyGeneration = 0;
  int _statementGeneration = 0;
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

  bool _isLoading = false;
  bool _isStatementLoading = false;

  List<Map<String, dynamic>> get searchResults => _searchResults;
  List<Map<String, dynamic>> get occupancyStats => _occupancyStats;
  AccountStatementReport? get accountStatementReport => _accountStatementReport;
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
  /// a session switch or loss/change of reports.view.
  void syncAuthorization({required int? userId, required bool canViewReports}) {
    if (_authorizedUserId != userId ||
        (_hadReportsAccess != null && _hadReportsAccess != canViewReports)) {
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
    _propertyInquiryGeneration++;
    _searchResults = [];
    _occupancyStats = [];
    _accountStatementReport = null;
    _isStatementLoading = false;
    _statementErrorMessage = null;
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
