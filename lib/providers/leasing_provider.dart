import 'package:flutter/material.dart';
import '../database/database_helper.dart';

class LeasingProvider with ChangeNotifier {
  List<Map<String, dynamic>> _tenants = [];
  List<Map<String, dynamic>> _vacantUnits = [];
  List<Map<String, dynamic>> _contracts = [];
  List<Map<String, dynamic>> _nationalities = [];

  bool _isLoading = false;

  List<Map<String, dynamic>> get tenants => _tenants;
  List<Map<String, dynamic>> get vacantUnits => _vacantUnits;
  List<Map<String, dynamic>> get contracts => _contracts;
  List<Map<String, dynamic>> get nationalities => _nationalities;
  bool get isLoading => _isLoading;

  Future<void> loadInitialData() async {
    _isLoading = true;
    notifyListeners();

    _tenants = await DatabaseHelper.instance.getAllTenants();
    _vacantUnits = await DatabaseHelper.instance.getVacantUnits();
    _contracts = await DatabaseHelper.instance.getAllContracts();
    _nationalities = await DatabaseHelper.instance.getLookupData(
      'nationalities',
    );

    _isLoading = false;
    notifyListeners();
  }

  Future<void> addTenant(Map<String, dynamic> tenant) async {
    await DatabaseHelper.instance.insertTenantWithAccount(tenant);
    await loadInitialData();
  }

  Future<int> addContract(
    Map<String, dynamic> contract,
    List<Map<String, dynamic>> installments,
  ) async {
    final contractId = await DatabaseHelper.instance
        .insertContractWithInstallments(contract, installments);
    await loadInitialData();
    return contractId;
  }

  Future<void> cancelContract(int contractId) async {
    await DatabaseHelper.instance.cancelContract(contractId);
    await loadInitialData();
  }
}
