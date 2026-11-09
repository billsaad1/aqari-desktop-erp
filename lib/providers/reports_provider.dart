import 'package:flutter/material.dart';
import '../database/database_helper.dart';

class ReportsProvider with ChangeNotifier {
  List<Map<String, dynamic>> _searchResults = [];
  List<Map<String, dynamic>> _occupancyStats = [];
  List<Map<String, dynamic>> _accountStatement = [];
  List<Map<String, dynamic>> _dueInstallments = [];
  List<Map<String, dynamic>> _expiringContracts = [];

  bool _isLoading = false;

  List<Map<String, dynamic>> get searchResults => _searchResults;
  List<Map<String, dynamic>> get occupancyStats => _occupancyStats;
  List<Map<String, dynamic>> get accountStatement => _accountStatement;
  List<Map<String, dynamic>> get dueInstallments => _dueInstallments;
  List<Map<String, dynamic>> get expiringContracts => _expiringContracts;
  bool get isLoading => _isLoading;

  Future<void> search(String query) async {
    _isLoading = true;
    notifyListeners();

    if (query.isNotEmpty) {
      _searchResults = await DatabaseHelper.instance.searchTenantsAndContracts(query);
    } else {
      _searchResults = [];
    }

    _isLoading = false;
    notifyListeners();
  }

  Future<void> loadOccupancyStats() async {
    _isLoading = true;
    notifyListeners();

    _occupancyStats = await DatabaseHelper.instance.getUnitOccupancyStats();

    _isLoading = false;
    notifyListeners();
  }

  Future<void> loadAccountStatement(int accountId, String startDate, String endDate) async {
    _isLoading = true;
    notifyListeners();

    _accountStatement = await DatabaseHelper.instance.getAccountStatement(accountId, startDate, endDate);

    _isLoading = false;
    notifyListeners();
  }

  Future<void> loadAlertsDashboard() async {
    _isLoading = true;
    notifyListeners();

    _dueInstallments = await DatabaseHelper.instance.getDueInstallments(3); // within 3 days
    _expiringContracts = await DatabaseHelper.instance.getExpiringContracts(30); // within 30 days

    _isLoading = false;
    notifyListeners();
  }
}
