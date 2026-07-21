import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../../utils/reading_text_range.dart';
import 'novel_text_layout.dart';

class SelectableNovelText extends StatefulWidget {
  const SelectableNovelText({
    super.key,
    required this.text,
    required this.style,
    required this.paragraphSpacing,
    this.globalStartOffset = 0,
    this.previousCodeUnit,
    this.highlightRange = TextRange.empty,
    this.highlightColor,
    this.selectionColor,
    this.textAlign = TextAlign.justify,
    this.richTextKey,
    this.onListenFromOffset,
    this.useNativeSelection = true,
  });

  final String text;
  final TextStyle style;
  final double paragraphSpacing;
  final int globalStartOffset;
  final int? previousCodeUnit;
  final TextRange highlightRange;
  final Color? highlightColor;
  final Color? selectionColor;
  final TextAlign textAlign;
  final Key? richTextKey;
  final ValueChanged<int>? onListenFromOffset;
  final bool useNativeSelection;

  @override
  State<SelectableNovelText> createState() => _SelectableNovelTextState();
}

class _SelectableNovelTextState extends State<SelectableNovelText> {
  final SelectionListenerNotifier _selectionNotifier =
      SelectionListenerNotifier();
  final GlobalKey _renderKey = GlobalKey();
  ContextMenuController? _passiveMenuController;
  TextRange _passiveSelection = TextRange.empty;
  bool _disposing = false;

  @override
  void didUpdateWidget(covariant SelectableNovelText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text ||
        oldWidget.globalStartOffset != widget.globalStartOffset ||
        oldWidget.useNativeSelection != widget.useNativeSelection) {
      _passiveMenuController?.remove();
      _passiveMenuController = null;
      _passiveSelection = TextRange.empty;
    }
  }

  @override
  void dispose() {
    _disposing = true;
    _passiveMenuController?.remove();
    _selectionNotifier.dispose();
    super.dispose();
  }

  TextRange? _selectedLocalRange() {
    if (!_selectionNotifier.registered) return null;
    final selected = _selectionNotifier.selection.range;
    if (selected == null) return null;
    final forward = selected.startOffset <= selected.endOffset;
    final start = (forward ? selected.startOffset : selected.endOffset)
        .clamp(0, widget.text.length)
        .toInt();
    final end = (forward ? selected.endOffset : selected.startOffset)
        .clamp(0, widget.text.length)
        .toInt();
    return end > start ? TextRange(start: start, end: end) : null;
  }

  void _clearSelection(SelectableRegionState state) {
    ContextMenuController.removeAny();
    state.clearSelection();
  }

  void _listenFromSelection(SelectableRegionState state) {
    final range = _selectedLocalRange();
    if (range == null) return;
    final paragraphStart = readingParagraphStartForOffset(
      widget.text,
      range.start,
    );
    final offset = widget.globalStartOffset + paragraphStart;
    _clearSelection(state);
    widget.onListenFromOffset?.call(offset);
  }

  void _copyCanonicalSelection(SelectableRegionState state) {
    final range = _selectedLocalRange();
    if (range == null) return;
    final selectedText = widget.text.substring(range.start, range.end);
    _clearSelection(state);
    unawaited(Clipboard.setData(ClipboardData(text: selectedText)));
  }

  void _copyCanonicalSelectionFromShortcut() {
    final range = _selectedLocalRange();
    if (range == null) return;
    final selectedText = widget.text.substring(range.start, range.end);
    unawaited(Clipboard.setData(ClipboardData(text: selectedText)));
  }

  void _shareCanonicalSelection(SelectableRegionState state) {
    final range = _selectedLocalRange();
    if (range == null) return;
    final selectedText = widget.text.substring(range.start, range.end);
    _clearSelection(state);
    unawaited(_shareText(selectedText));
  }

  Future<void> _shareText(String text) async {
    try {
      await SystemChannels.platform.invokeMethod<void>('Share.invoke', text);
    } catch (_) {
      // Sharing is platform-dependent; copying remains available everywhere.
    }
  }

  Widget _buildContextMenu(BuildContext context, SelectableRegionState state) {
    final defaultItems = state.contextMenuButtonItems.expand((item) {
      return switch (item.type) {
        ContextMenuButtonType.copy => <ContextMenuButtonItem>[
          item.copyWith(onPressed: () => _copyCanonicalSelection(state)),
        ],
        ContextMenuButtonType.share => <ContextMenuButtonItem>[
          item.copyWith(onPressed: () => _shareCanonicalSelection(state)),
        ],
        ContextMenuButtonType.selectAll => <ContextMenuButtonItem>[item],
        _ => const <ContextMenuButtonItem>[],
      };
    });
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: state.contextMenuAnchors,
      buttonItems: <ContextMenuButtonItem>[
        if (widget.onListenFromOffset != null)
          ContextMenuButtonItem(
            label: '从本段听',
            onPressed: () => _listenFromSelection(state),
          ),
        ...defaultItems,
      ],
    );
  }

  RenderParagraph? _renderParagraph() {
    final render = _renderKey.currentContext?.findRenderObject();
    return render is RenderParagraph && render.hasSize ? render : null;
  }

  void _showPassiveContextMenu(Offset globalPosition) {
    final paragraph = _renderParagraph();
    if (paragraph == null || widget.text.isEmpty) return;
    final localPosition = paragraph.globalToLocal(globalPosition);
    final offset = paragraph
        .getPositionForOffset(localPosition)
        .offset
        .clamp(0, widget.text.length - 1)
        .toInt();
    final range = paragraphRangeForOffset(widget.text, offset);
    if (!range.isValid || range.isCollapsed) return;

    _passiveMenuController?.remove();
    setState(() => _passiveSelection = range);
    late final ContextMenuController controller;
    controller = ContextMenuController(
      onRemove: () {
        if (identical(_passiveMenuController, controller)) {
          _passiveMenuController = null;
        }
        if (!_disposing && mounted && _passiveSelection.isValid) {
          setState(() => _passiveSelection = TextRange.empty);
        }
      },
    );
    _passiveMenuController = controller;
    final selectedText = widget.text.substring(range.start, range.end);
    controller.show(
      context: context,
      contextMenuBuilder: (context) {
        return AdaptiveTextSelectionToolbar.buttonItems(
          anchors: TextSelectionToolbarAnchors(primaryAnchor: globalPosition),
          buttonItems: <ContextMenuButtonItem>[
            if (widget.onListenFromOffset != null)
              ContextMenuButtonItem(
                label: '从本段听',
                onPressed: () {
                  controller.remove();
                  widget.onListenFromOffset?.call(
                    widget.globalStartOffset + range.start,
                  );
                },
              ),
            ContextMenuButtonItem(
              type: ContextMenuButtonType.copy,
              onPressed: () {
                controller.remove();
                unawaited(Clipboard.setData(ClipboardData(text: selectedText)));
              },
            ),
            if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android)
              ContextMenuButtonItem(
                type: ContextMenuButtonType.share,
                onPressed: () {
                  controller.remove();
                  unawaited(_shareText(selectedText));
                },
              ),
          ],
        );
      },
    );
  }

  Widget _buildRichText(Color selectionColor) {
    final passiveRange = _passiveSelection.isValid
        ? TextRange(
            start: widget.globalStartOffset + _passiveSelection.start,
            end: widget.globalStartOffset + _passiveSelection.end,
          )
        : TextRange.empty;
    return Builder(
      key: _renderKey,
      builder: (context) {
        return RichText(
          key: widget.richTextKey,
          textScaler: TextScaler.noScaling,
          textAlign: widget.textAlign,
          softWrap: true,
          overflow: TextOverflow.clip,
          selectionRegistrar: widget.useNativeSelection
              ? SelectionContainer.maybeOf(context)
              : null,
          selectionColor: selectionColor,
          text: NovelTextLayout.buildSpan(
            text: widget.text,
            globalStartOffset: widget.globalStartOffset,
            previousCodeUnit: widget.previousCodeUnit,
            style: widget.style,
            paragraphSpacing: widget.paragraphSpacing,
            highlightRange: passiveRange.isValid
                ? passiveRange
                : widget.highlightRange,
            highlightColor: passiveRange.isValid
                ? selectionColor
                : widget.highlightColor,
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final selectionColor =
        widget.selectionColor ??
        Theme.of(context).colorScheme.primary.withValues(alpha: 0.28);
    if (!widget.useNativeSelection) {
      return GestureDetector(
        behavior: HitTestBehavior.translucent,
        onLongPressStart: widget.onListenFromOffset == null
            ? null
            : (details) => _showPassiveContextMenu(details.globalPosition),
        onSecondaryTapUp: (details) =>
            _showPassiveContextMenu(details.globalPosition),
        child: _buildRichText(selectionColor),
      );
    }
    return Actions(
      actions: <Type, Action<Intent>>{
        CopySelectionTextIntent: CallbackAction<CopySelectionTextIntent>(
          onInvoke: (_) {
            _copyCanonicalSelectionFromShortcut();
            return null;
          },
        ),
      },
      child: SelectionArea(
        contextMenuBuilder: _buildContextMenu,
        child: SelectionListener(
          selectionNotifier: _selectionNotifier,
          child: _buildRichText(selectionColor),
        ),
      ),
    );
  }
}
