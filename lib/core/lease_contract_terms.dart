class LeaseContractTerms {
  LeaseContractTerms._();

  /// Starter terms are stored in company settings and remain editable there.
  static const List<String> defaultClauses = [
    'لا يجوز للطرف الثاني أن يؤجر العقار بهذا العقد لأي شخص من جانبه.',
    'الطرف الأول غير ملزم بأي تعويض عما قد يقوم به الطرف الثاني من إصلاح أو تحسين في العقار المؤجر.',
    'عند رغبة أحد الطرفين في إخلاء العقار المؤجر فيجب إبلاغ الطرف الآخر قبل ذلك بمدة شهرين كتابياً، وبدون معارضة من الطرف الثاني إذا كانت الرغبة من الطرف الأول.',
    'على الطرف الثاني التحلي بالأخلاق الحميدة مع من يشتركون معه في المبنى، وعدم صدور أي شكاوى من قبل جيرانه لتعريضهم لأي أذى من قبله.',
    'عند خروج الطرف الثاني من العقار عليه إصلاح أو دفع قيمة الإصلاح لأي تلف حصل في العقار نتيجة استعماله خلال فترة استئجاره.',
    'على الطرف الثاني عدم ترك أي نوع من المتروكات أو الأثاث التالف أو البضاعة خارج حدود العقار المؤجر له، مثل مدخل العمارة أو السلم أو السطح أو ارتدادات العقار أو الرصيف.',
    'قراءة عداد الكهرباء عند بدء الإيجار.',
    'حرر هذا العقد من نسختين، مع كل طرف نسخة، والتزم الطرفان باحترام بنوده كاملة، والله الموفق.',
  ];

  static String get defaultText => defaultClauses.join('\n');

  static List<String> resolve(Object? savedText) {
    final raw = savedText?.toString() ?? '';
    final clauses = raw
        .split(RegExp(r'\r?\n'))
        .map(
          (line) => line
              .replaceFirst(RegExp(r'^\s*(?:[\d٠-٩۰-۹]+\s*[.)-]|[•\-])\s*'), '')
              .trim(),
        )
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
    return clauses.isEmpty ? defaultClauses : clauses;
  }
}
