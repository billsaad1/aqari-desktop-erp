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
    _isLoading = true;
    notifyListeners();

    try {
      _occupancyStats = await DatabaseHelper.instance.getUnitOccupancyStats();
      _errorMessage = null;
    } catch (e) {
      _errorMessage = 'تعذر تحميل تقرير الإشغال: $e';
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> loadAccountStatement(
    int accountId,
    String startDate,
    String endDate,
  ) async {
    _isLoading = true;
    notifyListeners();

    try {
      _accountOpeningBalance = await DatabaseHelper.instance
          .getAccountOpeningBalance(accountId, startDate);
      _accountStatement = await DatabaseHelper.instance.getAccountStatement(
        accountId,
        startDate,
        endDate,
      );
      _errorMessage = null;
    } catch (e) {
      _accountStatement = [];
      _errorMessage = 'تعذر تحميل كشف الحساب: $e';
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> loadAlertsDashboard() async {
    _isLoading = true;
    notifyListeners();

    try {
      _dueInstallments = await DatabaseHelper.instance.getDueInstallments(3);
      _expiringContracts = await DatabaseHelper.instance.getExpiringContracts(
        30,
      );
      _errorMessage = null;
    } catch (e) {
      _errorMessage = 'تعذر تحميل التنبيهات: $e';
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }
}
