class CompanyInfo {
  final int? id;
  final String nameAr;
  final String? nameEn;
  final String? activity; // Retaining for backwards compatibility
  final String? address;  // Retaining for backwards compatibility
  final String? defaultCurrency;
  final String? taxNumber;
  final String? commercialRegister;
  final String? logoPath;
  final String? termsConditions;
  final String? activityNameAr;
  final String? activityNameEn;
  final String? addressAr;
  final String? addressEn;
  final String? poBox;
  final String? telephone;
  final String? fax;
  final String? mobile;

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
    this.activityNameAr,
    this.activityNameEn,
    this.addressAr,
    this.addressEn,
    this.poBox,
    this.telephone,
    this.fax,
    this.mobile,
  });

  factory CompanyInfo.fromMap(Map<String, dynamic> map) {
    return CompanyInfo(
      id: map['id'],
      nameAr: map['name_ar'] ?? '',
      nameEn: map['name_en'],
      activity: map['activity'],
      address: map['address'],
      defaultCurrency: map['default_currency'],
      taxNumber: map['tax_number'],
      commercialRegister: map['commercial_register'],
      logoPath: map['logo_path'],
      termsConditions: map['terms_conditions'],
      activityNameAr: map['activity_name_ar'],
      activityNameEn: map['activity_name_en'],
      addressAr: map['address_ar'],
      addressEn: map['address_en'],
      poBox: map['po_box'],
      telephone: map['telephone'],
      fax: map['fax'],
      mobile: map['mobile'],
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
      'activity_name_ar': activityNameAr,
      'activity_name_en': activityNameEn,
      'address_ar': addressAr,
      'address_en': addressEn,
      'po_box': poBox,
      'telephone': telephone,
      'fax': fax,
      'mobile': mobile,
    };
  }
}
