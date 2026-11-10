import 'package:flutter/material.dart';

/// DataTable wrapper with consistent horizontal scrolling and desktop row states.
/// Rows remain a basic cursor unless the row/cell actually has an action.
class ErpDataTable extends StatelessWidget {
  const ErpDataTable({
    super.key,
    required this.columns,
    required this.rows,
    this.sortColumnIndex,
    this.sortAscending = true,
    this.onSelectAll,
    this.decoration,
    this.dataRowColor,
    this.dataRowMinHeight,
    this.dataRowMaxHeight,
    this.dataTextStyle,
    this.headingRowColor,
    this.headingRowHeight,
    this.headingTextStyle,
    this.horizontalMargin,
    this.columnSpacing,
    this.showCheckboxColumn = true,
    this.showBottomBorder = false,
    this.dividerThickness,
    this.checkboxHorizontalMargin,
    this.border,
    this.clipBehavior = Clip.none,
  });

  final List<DataColumn> columns;
  final List<DataRow> rows;
  final int? sortColumnIndex;
  final bool sortAscending;
  final ValueChanged<bool?>? onSelectAll;
  final Decoration? decoration;
  final WidgetStateProperty<Color?>? dataRowColor;
  final double? dataRowMinHeight;
  final double? dataRowMaxHeight;
  final TextStyle? dataTextStyle;
  final WidgetStateProperty<Color?>? headingRowColor;
  final double? headingRowHeight;
  final TextStyle? headingTextStyle;
  final double? horizontalMargin;
  final double? columnSpacing;
  final bool showCheckboxColumn;
  final bool showBottomBorder;
  final double? dividerThickness;
  final double? checkboxHorizontalMargin;
  final TableBorder? border;
  final Clip clipBehavior;

  bool _hasAction(DataRow row) {
    return row.onSelectChanged != null ||
        row.onLongPress != null ||
        row.cells.any(
          (cell) =>
              cell.onTap != null ||
              cell.onDoubleTap != null ||
              cell.onLongPress != null ||
              cell.onTapDown != null,
        );
  }

  void _trackHover(bool _) {}

  @override
  Widget build(BuildContext context) {
    final styledRows = rows
        .map((row) {
          final hasAction = _hasAction(row);
          return DataRow(
            key: row.key,
            selected: row.selected,
            onSelectChanged: row.onSelectChanged,
            onLongPress: row.onLongPress,
            onHover: row.onHover ?? _trackHover,
            color: row.color,
            mouseCursor:
                row.mouseCursor ??
                WidgetStatePropertyAll<MouseCursor?>(
                  hasAction
                      ? SystemMouseCursors.click
                      : SystemMouseCursors.basic,
                ),
            cells: row.cells,
          );
        })
        .toList(growable: false);

    return Scrollbar(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          columns: columns,
          rows: styledRows,
          sortColumnIndex: sortColumnIndex,
          sortAscending: sortAscending,
          onSelectAll: onSelectAll,
          decoration: decoration,
          dataRowColor: dataRowColor,
          dataRowMinHeight: dataRowMinHeight,
          dataRowMaxHeight: dataRowMaxHeight,
          dataTextStyle: dataTextStyle,
          headingRowColor: headingRowColor,
          headingRowHeight: headingRowHeight,
          headingTextStyle: headingTextStyle,
          horizontalMargin: horizontalMargin,
          columnSpacing: columnSpacing,
          showCheckboxColumn: showCheckboxColumn,
          showBottomBorder: showBottomBorder,
          dividerThickness: dividerThickness,
          checkboxHorizontalMargin: checkboxHorizontalMargin,
          border: border,
          clipBehavior: clipBehavior,
        ),
      ),
    );
  }
}
