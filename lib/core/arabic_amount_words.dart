/// Spells out a monetary amount in Arabic for formal business documents.
class ArabicAmountWords {
  const ArabicAmountWords._();

  static const _currencyForms = <String, _CurrencyForms>{
    'ريال سعودي': _CurrencyForms(
      majorOne: 'ريال سعودي واحد',
      majorTwo: 'ريالان سعوديان',
      majorSingular: 'ريال سعودي',
      majorPlural: 'ريالات سعودية',
      minorOne: 'هللة واحدة',
      minorTwo: 'هللتان',
      minorSingular: 'هللة',
      minorPlural: 'هللات',
    ),
    'ريال يمني': _CurrencyForms(
      majorOne: 'ريال يمني واحد',
      majorTwo: 'ريالان يمنيان',
      majorSingular: 'ريال يمني',
      majorPlural: 'ريالات يمنية',
      minorOne: 'فلس واحد',
      minorTwo: 'فلسان',
      minorSingular: 'فلس',
      minorPlural: 'فلوس',
    ),
    'دولار أمريكي': _CurrencyForms(
      majorOne: 'دولار أمريكي واحد',
      majorTwo: 'دولاران أمريكيان',
      majorSingular: 'دولار أمريكي',
      majorPlural: 'دولارات أمريكية',
      minorOne: 'سنت واحد',
      minorTwo: 'سنتان',
      minorSingular: 'سنت',
      minorPlural: 'سنتات',
    ),
    'درهم إماراتي': _CurrencyForms(
      majorOne: 'درهم إماراتي واحد',
      majorTwo: 'درهمان إماراتيان',
      majorSingular: 'درهم إماراتي',
      majorPlural: 'دراهم إماراتية',
      minorOne: 'فلس واحد',
      minorTwo: 'فلسان',
      minorSingular: 'فلس',
      minorPlural: 'فلوس',
    ),
    'دينار كويتي': _CurrencyForms(
      majorOne: 'دينار كويتي واحد',
      majorTwo: 'ديناران كويتيان',
      majorSingular: 'دينار كويتي',
      majorPlural: 'دنانير كويتية',
      minorOne: 'فلس واحد',
      minorTwo: 'فلسان',
      minorSingular: 'فلس',
      minorPlural: 'فلوس',
    ),
    'ريال عماني': _CurrencyForms(
      majorOne: 'ريال عماني واحد',
      majorTwo: 'ريالان عمانيان',
      majorSingular: 'ريال عماني',
      majorPlural: 'ريالات عمانية',
      minorOne: 'بيسة واحدة',
      minorTwo: 'بيستان',
      minorSingular: 'بيسة',
      minorPlural: 'بيسات',
    ),
    'ريال قطري': _CurrencyForms(
      majorOne: 'ريال قطري واحد',
      majorTwo: 'ريالان قطريان',
      majorSingular: 'ريال قطري',
      majorPlural: 'ريالات قطرية',
      minorOne: 'درهم واحد',
      minorTwo: 'درهمان',
      minorSingular: 'درهم',
      minorPlural: 'دراهم',
    ),
    'دينار بحريني': _CurrencyForms(
      majorOne: 'دينار بحريني واحد',
      majorTwo: 'ديناران بحرينيان',
      majorSingular: 'دينار بحريني',
      majorPlural: 'دنانير بحرينية',
      minorOne: 'فلس واحد',
      minorTwo: 'فلسان',
      minorSingular: 'فلس',
      minorPlural: 'فلوس',
    ),
    'جنيه مصري': _CurrencyForms(
      majorOne: 'جنيه مصري واحد',
      majorTwo: 'جنيهان مصريان',
      majorSingular: 'جنيه مصري',
      majorPlural: 'جنيهات مصرية',
      minorOne: 'قرش واحد',
      minorTwo: 'قرشان',
      minorSingular: 'قرش',
      minorPlural: 'قروش',
    ),
    'يورو': _CurrencyForms(
      majorOne: 'يورو واحد',
      majorTwo: 'يوروان',
      majorSingular: 'يورو',
      majorPlural: 'يورو',
      minorOne: 'سنت واحد',
      minorTwo: 'سنتان',
      minorSingular: 'سنت',
      minorPlural: 'سنتات',
    ),
  };

  static String format(double amount, String currency) {
    final cents = (amount.abs() * 100).round();
    final majorUnits = cents ~/ 100;
    final minorUnits = cents % 100;
    final forms = _currencyForms[currency] ?? _fallbackForms(currency);
    final majorText = _majorAmountInWords(majorUnits, forms);
    final sign = amount.isNegative ? 'سالب ' : '';
    if (minorUnits == 0) return '$sign$majorText';
    return '$sign$majorText و${_minorAmountInWords(minorUnits, forms)}';
  }

  static String _majorAmountInWords(int value, _CurrencyForms forms) {
    if (value == 1) return forms.majorOne;
    if (value == 2) return forms.majorTwo;
    final unit = value >= 3 && value <= 10
        ? forms.majorPlural
        : forms.majorSingular;
    return '${_integerInWords(value)} $unit';
  }

  static String _minorAmountInWords(int value, _CurrencyForms forms) {
    if (value == 1) return forms.minorOne;
    if (value == 2) return forms.minorTwo;
    final unit = value >= 3 && value <= 10
        ? forms.minorPlural
        : forms.minorSingular;
    return '${_integerInWords(value)} $unit';
  }

  static _CurrencyForms _fallbackForms(String currency) => _CurrencyForms(
    majorOne: '$currency واحد',
    majorTwo: 'اثنان $currency',
    majorSingular: currency,
    majorPlural: currency,
    minorOne: 'جزء واحد من مئة $currency',
    minorTwo: 'جزآن من مئة $currency',
    minorSingular: 'جزء من مئة $currency',
    minorPlural: 'أجزاء من مئة $currency',
  );

  static String _integerInWords(int value) {
    if (value == 0) return 'صفر';
    if (value < 0) return 'سالب ${_integerInWords(-value)}';
    const scales = ['', 'ألف', 'مليون', 'مليار', 'تريليون'];
    const pluralScales = ['', 'آلاف', 'ملايين', 'مليارات', 'تريليونات'];
    final groups = <int>[];
    var remaining = value;
    while (remaining > 0) {
      groups.add(remaining % 1000);
      remaining ~/= 1000;
    }
    if (groups.length > scales.length) return value.toString();
    final words = <String>[];
    for (var i = groups.length - 1; i >= 0; i--) {
      final group = groups[i];
      if (group == 0) continue;
      if (i == 0) {
        words.add(_underThousand(group));
      } else if (group == 1) {
        words.add(scales[i]);
      } else if (group == 2) {
        words.add('${scales[i]}ان');
      } else if (group <= 10) {
        words.add('${_underThousand(group)} ${pluralScales[i]}');
      } else {
        words.add('${_underThousand(group)} ${scales[i]}');
      }
    }
    return words.join(' و');
  }

  static String _underThousand(int value) {
    const ones = [
      '',
      'واحد',
      'اثنان',
      'ثلاثة',
      'أربعة',
      'خمسة',
      'ستة',
      'سبعة',
      'ثمانية',
      'تسعة',
      'عشرة',
      'أحد عشر',
      'اثنا عشر',
      'ثلاثة عشر',
      'أربعة عشر',
      'خمسة عشر',
      'ستة عشر',
      'سبعة عشر',
      'ثمانية عشر',
      'تسعة عشر',
    ];
    const tens = [
      '',
      '',
      'عشرون',
      'ثلاثون',
      'أربعون',
      'خمسون',
      'ستون',
      'سبعون',
      'ثمانون',
      'تسعون',
    ];
    const hundreds = [
      '',
      'مئة',
      'مئتان',
      'ثلاثمئة',
      'أربعمئة',
      'خمسمئة',
      'ستمئة',
      'سبعمئة',
      'ثمانمئة',
      'تسعمئة',
    ];
    final parts = <String>[];
    final hundredsValue = value ~/ 100;
    final remainder = value % 100;
    if (hundredsValue > 0) parts.add(hundreds[hundredsValue]);
    if (remainder > 0) {
      if (remainder < 20) {
        parts.add(ones[remainder]);
      } else {
        final unit = remainder % 10;
        final ten = remainder ~/ 10;
        parts.add(unit == 0 ? tens[ten] : '${ones[unit]} و${tens[ten]}');
      }
    }
    return parts.join(' و');
  }
}

class _CurrencyForms {
  const _CurrencyForms({
    required this.majorOne,
    required this.majorTwo,
    required this.majorSingular,
    required this.majorPlural,
    required this.minorOne,
    required this.minorTwo,
    required this.minorSingular,
    required this.minorPlural,
  });

  final String majorOne;
  final String majorTwo;
  final String majorSingular;
  final String majorPlural;
  final String minorOne;
  final String minorTwo;
  final String minorSingular;
  final String minorPlural;
}
