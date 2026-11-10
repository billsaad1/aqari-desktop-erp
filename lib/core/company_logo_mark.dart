import 'dart:io';

import 'package:flutter/material.dart';

import '../database/database_helper.dart';

/// Loads the locally uploaded company logo and falls back to a business glyph.
class CompanyLogoMark extends StatefulWidget {
  const CompanyLogoMark({
    super.key,
    required this.size,
    required this.iconColor,
    required this.backgroundColor,
    this.radius = 16,
    this.padding = 7,
  });

  final double size;
  final Color iconColor;
  final Color backgroundColor;
  final double radius;
  final double padding;

  @override
  State<CompanyLogoMark> createState() => _CompanyLogoMarkState();
}

class _CompanyLogoMarkState extends State<CompanyLogoMark> {
  late final Future<Map<String, dynamic>?> _companyInfo;

  @override
  void initState() {
    super.initState();
    _companyInfo = DatabaseHelper.instance.getCompanyInfo();
  }

  Widget _fallback() => Icon(
    Icons.apartment_rounded,
    size: widget.size * 0.52,
    color: widget.iconColor,
  );

  @override
  Widget build(BuildContext context) {
    return Container(
      width: widget.size,
      height: widget.size,
      padding: EdgeInsets.all(widget.padding),
      decoration: BoxDecoration(
        color: widget.backgroundColor,
        borderRadius: BorderRadius.circular(widget.radius),
      ),
      clipBehavior: Clip.antiAlias,
      child: FutureBuilder<Map<String, dynamic>?>(
        future: _companyInfo,
        builder: (context, snapshot) {
          final path = snapshot.data?['logo_path']?.toString().trim() ?? '';
          if (!snapshot.hasData || path.isEmpty) return _fallback();
          return Image.file(
            File(path),
            fit: BoxFit.contain,
            errorBuilder: (context, error, stackTrace) => _fallback(),
          );
        },
      ),
    );
  }
}
