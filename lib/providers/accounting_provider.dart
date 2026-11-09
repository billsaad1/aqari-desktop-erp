import 'package:flutter/material.dart';
import '../database/database_helper.dart';

class AccountingProvider with ChangeNotifier {
  List<Map<String, dynamic>> _accounts = [];
  List<Map<String, dynamic>> _costCenters = [];
  bool _isLoading = false;

  List<Map<String, dynamic>> get accounts => _accounts;
  List<Map<String, dynamic>> get costCenters => _costCenters;
  bool get isLoading => _isLoading;

  Future<void> loadAccounts() async {
    _isLoading = true;
    notifyListeners();

    _accounts = await DatabaseHelper.instance.getAllAccounts();

    _isLoading = false;
    notifyListeners();
  }

  Future<void> loadCostCenters() async {
    _costCenters = await DatabaseHelper.instance.getLookupData('cost_centers');
    notifyListeners();
  }

  Future<void> addAccount(Map<String, dynamic> account) async {
    await DatabaseHelper.instance.insertAccount(account);
    await loadAccounts();
  }

  Future<void> saveJournalEntry(Map<String, dynamic> header, List<Map<String, dynamic>> lines) async {
    await DatabaseHelper.instance.insertJournalEntryWithLines(header, lines);
    await loadAccounts(); // Refresh balances
  }

  Future<void> saveGeneralVoucher(Map<String, dynamic> voucher, int cashAccountId, int oppositeAccountId, int? costCenterId, String voucherType) async {
    await DatabaseHelper.instance.insertGeneralVoucher(voucher, cashAccountId, oppositeAccountId, costCenterId, voucherType);
    await loadAccounts(); // Refresh balances
  }
}
