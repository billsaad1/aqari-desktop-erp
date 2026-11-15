import 'package:flutter/material.dart';
import '../core/permission_policy.dart';
import '../database/database_helper.dart';

class LeasingProvider with ChangeNotifier {
  List<Map<String, dynamic>> _tenants = [];
  List<Map<String, dynamic>> _vacantUnits = [];
  List<Map<String, dynamic>> _contracts = [];
  List<Map<String, dynamic>> _nationalities = [];

  bool _isLoading = false;
  int _loadGeneration = 0;

  List<Map<String, dynamic>> get tenants => _tenants;
  List<Map<String, dynamic>> get vacantUnits => _vacantUnits;
  List<Map<String, dynamic>> get contracts => _contracts;
  List<Map<String, dynamic>> get nationalities => _nationalities;
  bool get isLoading => _isLoading;

  Future<void> loadInitialData() async {
    final generation = ++_loadGeneration;
    _tenants = [];
    _vacantUnits = [];
    _contracts = [];
    _nationalities = [];
    _isLoading = true;
    notifyListeners();
    try {
      var tenants = <Map<String, dynamic>>[];
      var vacantUnits = <Map<String, dynamic>>[];
      var contracts = <Map<String, dynamic>>[];
      var nationalities = <Map<String, dynamic>>[];
      final canViewLeasing = PermissionRuntime.allows(
        'leasing',
        AppPermissionAction.view,
      );
      final canViewFinancial = PermissionRuntime.allows(
        'tenant_financial',
        AppPermissionAction.view,
      );
      if (canViewLeasing) {
        tenants = await DatabaseHelper.instance.getAllTenants();
        vacantUnits = await DatabaseHelper.instance.getVacantUnits();
        contracts = await DatabaseHelper.instance.getAllContracts();
        nationalities = await DatabaseHelper.instance.getLookupData(
          'nationalities',
        );
      } else if (canViewFinancial) {
        tenants = await DatabaseHelper.instance.getAllTenants();
        contracts = await DatabaseHelper.instance
            .getActiveTenantContractsForFinancial();
      }
      if (generation != _loadGeneration) return;
      _tenants = tenants;
      _vacantUnits = vacantUnits;
      _contracts = contracts;
      _nationalities = nationalities;
    } finally {
      if (generation == _loadGeneration) {
        _isLoading = false;
        notifyListeners();
      }
    }
  }

  void clearSensitiveData({bool notify = true}) {
    _loadGeneration++;
    _tenants = [];
    _vacantUnits = [];
    _contracts = [];
    _nationalities = [];
    _isLoading = false;
    if (notify) notifyListeners();
  }

  Future<void> addTenant(Map<String, dynamic> tenant) async {
    await DatabaseHelper.instance.insertTenantWithAccount(tenant);
    await loadInitialData();
  }

  Future<void> updateTenant(Map<String, dynamic> tenant) async {
    await DatabaseHelper.instance.updateTenant(tenant);
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
