import 'package:flutter/material.dart';
import '../database/database_helper.dart';

class ReportsProvider with ChangeNotifier {
  List<Map<String, dynamic>> _searchResults = [];
  List<Map<String, dynamic>> _occupancyStats = [];
  List<Map<String, dynamic>> _accountStatement = [];
  List<Map<String, dynamic>> _dueInstallments = [];
  List<Map<String, dynamic>> _expiringContracts = [];
  double _accountOpeningBalance = 0;
  int _searchGeneration = 0;
  int _occupancyGeneration = 0;
  int _statementGeneration = 0;
  int _alertsGeneration = 0;
  String? _errorMessage;

  bool _isLoading = false;

  List<Map<String, dynamic>> get searchResults => _searchResults;
  List<Map<String, dynamic>> get occupancyStats => _occupancyStats;
  List<Map<String, dynamic>> get accountStatement => _accountStatement;
  List<Map<String, dynamic>> get dueInstallments => _dueInstallments;
  List<Map<String, dynamic>> get expiringContracts => _expiringContracts;
  bool get isLoading => _isLoading;
  double get accountOpeningBalance => _accountOpeningBalance;
  String? get errorMessage => _errorMessage;

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
    _searchResults = [];
    _occupancyStats = [];
    _accountStatement = [];
    _accountOpeningBalance = 0;
    _isLoading = false;
    _errorMessage = null;
    if (notify) notifyListeners();
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
      if (generation == _searchGeneration)
        _errorMessage = 'تعذر تنفيذ الاستعلام: $e';
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
    _isLoading = true;
    notifyListeners();

    try {
      final openingBalance = await DatabaseHelper.instance
          .getAccountOpeningBalance(accountId, startDate);
      if (generation != _statementGeneration) return;
      final statement = await DatabaseHelper.instance.getAccountStatement(
        accountId,
        startDate,
        endDate,
      );
      if (generation == _statementGeneration) {
        _accountOpeningBalance = openingBalance;
        _accountStatement = statement;
        _errorMessage = null;
      }
    } catch (e) {
      if (generation == _statementGeneration) {
        _accountOpeningBalance = 0;
        _accountStatement = [];
        _errorMessage = 'تعذر تحميل كشف الحساب: $e';
      }
    } finally {
      if (generation == _statementGeneration) {
        _isLoading = false;
        notifyListeners();
      }
    }
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
