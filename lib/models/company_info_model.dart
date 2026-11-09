class CompanyInfo {
  final int? id;
  final String nameAr;
  final String? nameEn;
  final String? activity;
  final String? address;
  final String? defaultCurrency;
  final String? taxNumber;
  final String? commercialRegister;
  final String? logoPath;
  final String? termsConditions;

  CompanyInfo({
    this.id,
    required this.nameAr,
    this.nameEn,
    this.activity,
    this.address,
    this.defaultCurrency,
    this.taxNumber,
    this.commercialRegister,
    this.logoPath,
    this.termsConditions,
  });

  factory CompanyInfo.fromMap(Map<String, dynamic> map) {
    return CompanyInfo(
      id: map['id'],
      nameAr: map['name_ar'],
      nameEn: map['name_en'],
      activity: map['activity'],
      address: map['address'],
      defaultCurrency: map['default_currency'],
      taxNumber: map['tax_number'],
      commercialRegister: map['commercial_register'],
      logoPath: map['logo_path'],
      termsConditions: map['terms_conditions'],
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name_ar': nameAr,
      'name_en': nameEn,
      'activity': activity,
      'address': address,
      'default_currency': defaultCurrency,
      'tax_number': taxNumber,
      'commercial_register': commercialRegister,
      'logo_path': logoPath,
      'terms_conditions': termsConditions,
    };
  }
}
