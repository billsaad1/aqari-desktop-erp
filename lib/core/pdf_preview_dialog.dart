import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

import 'print_utils.dart';

enum PdfPreviewIntent { save, printDocument }

/// In-app preview of the exact PDF bytes that will be saved or printed.
class PdfDocumentPreviewDialog extends StatefulWidget {
  const PdfDocumentPreviewDialog({
    required this.bytes,
    required this.fileName,
    required this.preferredIntent,
    super.key,
  });

  final Uint8List bytes;
  final String fileName;
  final PdfPreviewIntent preferredIntent;

  static Future<void> show({
    required BuildContext context,
    required Uint8List bytes,
    required String fileName,
    required PdfPreviewIntent preferredIntent,
  }) => showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PdfDocumentPreviewDialog(
      bytes: bytes,
      fileName: fileName,
      preferredIntent: preferredIntent,
    ),
  );

  @override
  State<PdfDocumentPreviewDialog> createState() =>
      _PdfDocumentPreviewDialogState();
}

class _PdfDocumentPreviewDialogState extends State<PdfDocumentPreviewDialog> {
  bool _isWorking = false;
  String? _feedback;
  bool _feedbackIsError = false;

  Future<void> _save() async {
    if (_isWorking) return;
    setState(() {
      _isWorking = true;
      _feedback = null;
    });
    try {
      final saved = await PrintUtils.savePdf(widget.bytes, widget.fileName);
      if (!mounted) return;
      setState(() {
        _feedback = saved ? PrintUtils.savedPdfMessage : 'أُلغي حفظ الملف.';
        _feedbackIsError = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _feedback = 'تعذر حفظ PDF: $error';
        _feedbackIsError = true;
      });
    } finally {
      if (mounted) setState(() => _isWorking = false);
    }
  }

  Future<void> _print() async {
    if (_isWorking) return;
    setState(() {
      _isWorking = true;
      _feedback = null;
    });
    try {
      await PrintUtils.printPdf(widget.bytes, widget.fileName);
      if (!mounted) return;
      setState(() {
        _feedback = 'تم إرسال المستند إلى نافذة الطباعة.';
        _feedbackIsError = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _feedback = 'تعذرت الطباعة: $error';
        _feedbackIsError = true;
      });
    } finally {
      if (mounted) setState(() => _isWorking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final width = math.min(screen.width * 0.96, 1280.0).toDouble();
    final height = math.min(screen.height * 0.94, 960.0).toDouble();
    final saveIsPrimary = widget.preferredIntent == PdfPreviewIntent.save;

    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: SizedBox(
        width: width,
        height: height,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(20, 12, 12, 12),
              child: Row(
                children: [
                  Icon(
                    Icons.picture_as_pdf_outlined,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'معاينة المستند',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          'هذه هي النسخة نفسها التي ستُحفظ أو تُرسل للطباعة — ${PrintUtils.suggestedPdfName(widget.fileName)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'إغلاق المعاينة',
                    onPressed: _isWorking
                        ? null
                        : () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: PdfPreview(
                build: (_) async => widget.bytes,
                pdfFileName: PrintUtils.suggestedPdfName(widget.fileName),
                allowPrinting: false,
                allowSharing: false,
                canChangePageFormat: false,
                canChangeOrientation: false,
                canDebug: false,
                useActions: false,
                maxPageWidth: 1050,
                padding: const EdgeInsets.all(20),
                previewPageMargin: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                scrollViewDecoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                ),
                pdfPreviewPageDecoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(4),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x26000000),
                      blurRadius: 12,
                      offset: Offset(0, 4),
                    ),
                  ],
                ),
                loadingWidget: const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 12),
                      Text('جارٍ تجهيز معاينة الصفحات...'),
                    ],
                  ),
                ),
                onError: (_, error) => Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'تعذرت معاينة هذا المستند:\n$error',
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(16, 10, 16, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_feedback != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        _feedback!,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: _feedbackIsError
                              ? Theme.of(context).colorScheme.error
                              : Theme.of(context).colorScheme.primary,
                        ),
                      ),
                    ),
                  Row(
                    children: [
                      const Spacer(),
                      if (saveIsPrimary)
                        OutlinedButton.icon(
                          onPressed: _isWorking ? null : _print,
                          icon: const Icon(Icons.print_outlined),
                          label: const Text('طباعة'),
                        )
                      else
                        OutlinedButton.icon(
                          onPressed: _isWorking ? null : _save,
                          icon: const Icon(Icons.save_alt_outlined),
                          label: const Text('حفظ PDF'),
                        ),
                      const SizedBox(width: 10),
                      if (saveIsPrimary)
                        FilledButton.icon(
                          onPressed: _isWorking ? null : _save,
                          icon: _isWorking
                              ? const SizedBox.square(
                                  dimension: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.save_alt_outlined),
                          label: const Text('حفظ PDF'),
                        )
                      else
                        FilledButton.icon(
                          onPressed: _isWorking ? null : _print,
                          icon: _isWorking
                              ? const SizedBox.square(
                                  dimension: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.print_outlined),
                          label: const Text('طباعة'),
                        ),
                      const SizedBox(width: 10),
                      TextButton(
                        onPressed: _isWorking
                            ? null
                            : () => Navigator.of(context).pop(),
                        child: const Text('إغلاق'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
