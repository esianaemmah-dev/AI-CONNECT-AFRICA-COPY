import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:pdfrx/pdfrx.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/theme/app_colors.dart';
import '../../db/providers/db_provider.dart';
import '../../l10n/app_locale.dart';
import '../../shared/widgets/studio_page.dart';
import 'pdf_highlights.dart';

final readingActivityProvider = StateProvider<int>((ref) => 0);

enum PdfReadTheme { normal, night, eyeCare }

enum PdfPageFlow { vertical, horizontal }

const _themePref = 'pdf_reader_theme';
const _flowPref = 'pdf_reader_flow';
String _pagePref(String key) => 'pdf_reader_page_$key';

/// Read-only, offline PDF reader with browser/WPS-style controls.
///
/// The viewer owns document rendering; this screen owns session state,
/// navigation, search, appearance and reader chrome.
///
/// The file itself is never changed: highlights are the active learner's
/// own, kept beside it (`pdf_highlights.dart`). There is deliberately no
/// download, save-as or print.
class PdfReader extends ConsumerStatefulWidget {
  const PdfReader({
    super.key,
    required this.path,
    required this.title,
    required this.memoryKey,
    this.initialPage = 0,
    this.embedded = false,
    this.onFullScreen,
  });

  final String path;
  final String title;
  final String memoryKey;
  final int initialPage;
  final bool embedded;
  final VoidCallback? onFullScreen;

  @override
  ConsumerState<PdfReader> createState() => _PdfReaderState();
}

class _PdfReaderState extends ConsumerState<PdfReader> {
  late PdfViewerController _viewer;
  // Made in _onReady: pdfrx's searcher needs a loaded document.
  PdfTextSearcher? _searcher;

  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();
  final _pageController = TextEditingController();
  final _pageFocus = FocusNode();

  SharedPreferences? _prefs;
  PdfViewerParams? _params;
  List<PdfOutlineNode> _outline = const [];

  String _highlightKey = '';
  String _readingKey = '';
  List<PdfHighlight> _highlights = [];
  Map<int, List<PdfHighlight>> _highlightsByPage = const {};
  List<PdfPageTextRange> _selection = const [];

  bool _loaded = false;
  bool _showChrome = true;
  bool _showSearch = false;

  int _page = 1;
  int _pageCount = 0;
  int _startPage = 1;

  PdfReadTheme _theme = PdfReadTheme.normal;
  PdfPageFlow _flow = PdfPageFlow.vertical;

  @override
  void initState() {
    super.initState();
    _createViewer();
    _restore();
  }

  void _createViewer() {
    _disposeSearcher();
    _viewer = PdfViewerController();
  }

  void _disposeSearcher() {
    final searcher = _searcher;
    if (searcher == null) return;
    searcher
      ..removeListener(_onSearchChanged)
      ..dispose();
    _searcher = null;
  }

  Future<void> _restore() async {
    try {
      _prefs = await SharedPreferences.getInstance();
    } catch (_) {}

    int? studentId;
    try {
      studentId = (await ref.read(activeStudentProvider.future))?.id;
    } catch (_) {}

    final prefs = _prefs;
    final highlightKey = pdfHighlightKey(studentId, widget.memoryKey);
    final highlights = loadPdfHighlights(prefs, highlightKey);
    _readingKey = '${studentId ?? 'guest'}:${widget.memoryKey}';
    var savedPage = prefs?.getInt(_pagePref(_readingKey));
    if (savedPage == null && studentId != null) {
      savedPage = prefs?.getInt(_pagePref(widget.memoryKey));
      if (savedPage != null) {
        await prefs?.setInt(_pagePref(_readingKey), savedPage);
        await prefs?.remove(_pagePref(widget.memoryKey));
      }
    }
    savedPage ??= 1;
    final savedTheme = PdfReadTheme.values
        .asNameMap()[prefs?.getString(_themePref)];
    final savedFlow = PdfPageFlow.values
        .asNameMap()[prefs?.getString(_flowPref)];

    if (!mounted) return;

    setState(() {
      _theme = savedTheme ?? PdfReadTheme.normal;
      _flow = savedFlow ?? PdfPageFlow.vertical;
      _startPage = widget.initialPage > 0
          ? widget.initialPage
          : math.max(savedPage ?? 1, 1);
      _page = _startPage;
      _pageController.text = '$_page';
      _highlightKey = highlightKey;
      _setHighlights(highlights);
      _loaded = true;
    });
    if (studentId != null) {
      await prefs?.setBool('pdf_seen_$studentId:${widget.memoryKey}', true);
      if (mounted) ref.read(readingActivityProvider.notifier).state++;
    }
  }

  @override
  void dispose() {
    _disposeSearcher();
    _searchController.dispose();
    _searchFocus.dispose();
    _pageController.dispose();
    _pageFocus.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    if (mounted) setState(() {});
  }

  bool get _ready => _viewer.isReady && _pageCount > 0;

  bool get _touchPlatform => switch (Theme.of(context).platform) {
    TargetPlatform.android || TargetPlatform.iOS => true,
    _ => false,
  };

  // ---------------------------------------------------------------------------
  // Document/session
  // ---------------------------------------------------------------------------

  void _onReady(PdfDocument document, PdfViewerController controller) {
    if (!mounted) return;

    final count = document.pages.length;
    final page = _startPage.clamp(1, math.max(count, 1)).toInt();

    setState(() {
      _disposeSearcher();
      _searcher = PdfTextSearcher(controller)..addListener(_onSearchChanged);
      _pageCount = count;
      _page = page;
      _pageController.text = '$page';
    });

    document.loadOutline().then((outline) {
      if (mounted) setState(() => _outline = outline);
    }, onError: (_) {});
  }

  void _onPageChanged(int? page) {
    if (page == null || page == _page) return;

    setState(() => _page = page);
    if (!_pageFocus.hasFocus) _pageController.text = '$page';
    _prefs?.setInt(_pagePref(_readingKey), page);
    _prefs?.setString(
      'pdf_last_${_readingKey.split(':').first}',
      widget.memoryKey,
    );
  }

  // ---------------------------------------------------------------------------
  // Navigation
  // ---------------------------------------------------------------------------

  void _goToPage(int page) {
    if (!_ready) return;
    final target = page.clamp(1, _pageCount);
    _viewer.goToPage(pageNumber: target);
    if (!_pageFocus.hasFocus) _pageController.text = '$target';
  }

  void _submitPage(String value) {
    final page = int.tryParse(value.trim());
    if (page == null) {
      _pageController.text = '$_page';
    } else {
      _goToPage(page);
    }
    _pageFocus.unfocus();
  }

  void _fitWidth() {
    if (!_ready) return;
    final matrix = _viewer.calcMatrixFitWidthForPage(pageNumber: _page);
    if (matrix != null) _viewer.goTo(matrix);
  }

  void _fitPage() {
    if (!_ready) return;
    final matrix = _viewer.calcMatrixForFit(pageNumber: _page);
    if (matrix != null) _viewer.goTo(matrix);
  }

  // ---------------------------------------------------------------------------
  // Highlights
  // ---------------------------------------------------------------------------

  void _setHighlights(List<PdfHighlight> highlights) {
    _highlights = highlights;
    final byPage = <int, List<PdfHighlight>>{};
    for (final h in highlights) {
      (byPage[h.page] ??= []).add(h);
    }
    _highlightsByPage = byPage;
  }

  void _commitHighlights(List<PdfHighlight> highlights) {
    setState(() => _setHighlights(highlights));
    if (_viewer.isReady) _viewer.invalidate();
    savePdfHighlights(_prefs, _highlightKey, highlights);
  }

  Future<void> _onSelectionChange(PdfTextSelection selection) async {
    if (!selection.hasSelectedText) {
      _selection = const [];
      return;
    }
    try {
      _selection = await selection.getSelectedTextRanges();
    } catch (_) {
      _selection = const [];
    }
  }

  bool get _selectionHighlighted => _selection.any((range) {
    final rects = pdfLineRects(range);
    return (_highlightsByPage[range.pageNumber] ?? const []).any(
      (h) => h.overlaps(range.pageNumber, rects),
    );
  });

  Future<void> _highlightSelection(PdfTextSelectionDelegate delegate) async {
    final ranges = await delegate.getSelectedTextRanges();
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final added = <PdfHighlight>[
      for (final (i, range) in ranges.indexed)
        if (pdfLineRects(range) case final rects when rects.isNotEmpty)
          PdfHighlight(
            id: '$stamp-$i',
            page: range.pageNumber,
            rects: rects,
            text: range.text.trim(),
          ),
    ];
    await delegate.clearTextSelection();
    if (added.isEmpty || !mounted) return;
    _commitHighlights([..._highlights, ...added]);
  }

  Future<void> _removeSelectedHighlights(
    PdfTextSelectionDelegate delegate,
  ) async {
    final ranges = await delegate.getSelectedTextRanges();
    final hit = [
      for (final range in ranges) (range.pageNumber, pdfLineRects(range)),
    ];
    await delegate.clearTextSelection();
    if (!mounted) return;
    _commitHighlights([
      for (final h in _highlights)
        if (!hit.any((s) => h.overlaps(s.$1, s.$2))) h,
    ]);
  }

  void _removeHighlight(PdfHighlight highlight) => _commitHighlights([
    for (final h in _highlights)
      if (h.id != highlight.id) h,
  ]);

  void _customizeMenu(
    PdfViewerContextMenuBuilderParams params,
    List<ContextMenuButtonItem> items,
  ) {
    // Notes are read here, not taken away: no copy, like no download/print.
    items.removeWhere((item) => item.type == ContextMenuButtonType.copy);
    final delegate = params.textSelectionDelegate;
    if (!params.isTextSelectionEnabled || !delegate.hasSelectedText) return;
    items.insert(
      0,
      ContextMenuButtonItem(
        label: tr(context, 'Highlight'),
        onPressed: () {
          params.dismissContextMenu();
          _highlightSelection(delegate);
        },
      ),
    );
    if (_selectionHighlighted) {
      items.insert(
        1,
        ContextMenuButtonItem(
          label: tr(context, 'Remove highlight'),
          onPressed: () {
            params.dismissContextMenu();
            _removeSelectedHighlights(delegate);
          },
        ),
      );
    }
  }

  /// Swallows Ctrl/Cmd+C, which the viewer would otherwise copy with.
  bool? _onKey(
    PdfViewerKeyHandlerParams params,
    LogicalKeyboardKey key,
    bool isRealKeyPress,
  ) {
    final keys = HardwareKeyboard.instance;
    if (key == LogicalKeyboardKey.keyC &&
        (keys.isControlPressed || keys.isMetaPressed)) {
      return true;
    }
    return null;
  }

  void _paintHighlights(Canvas canvas, Rect pageRect, PdfPage page) {
    final onPage = _highlightsByPage[page.pageNumber];
    if (onPage == null) return;
    // Multiply, like a highlighter pen: the paper turns yellow, the ink
    // stays dark.
    final paint = Paint()
      ..color = const Color(0xFFFFEB3B)
      ..blendMode = BlendMode.multiply;
    for (final h in onPage) {
      for (final r in h.rects) {
        canvas.drawRect(
          r
              .toRect(page: page, scaledPageSize: pageRect.size)
              .translate(pageRect.left, pageRect.top),
          paint,
        );
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Search
  // ---------------------------------------------------------------------------

  void _openSearch() {
    setState(() {
      _showSearch = true;
      _showChrome = true;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocus.requestFocus();
    });
  }

  void _closeSearch() {
    _searcher?.resetTextSearch();
    _searchController.clear();
    setState(() => _showSearch = false);
  }

  void _search(String value) {
    final query = value.trim();
    if (query.isEmpty) {
      _searcher?.resetTextSearch();
    } else {
      _searcher?.startTextSearch(query);
    }
  }

  // ---------------------------------------------------------------------------
  // Appearance/view mode
  // ---------------------------------------------------------------------------

  void _setTheme(PdfReadTheme theme) {
    if (theme == _theme) return;
    setState(() {
      _theme = theme;
      _params = null;
    });
    _prefs?.setString(_themePref, theme.name);
  }

  void _setFlow(PdfPageFlow flow) {
    if (flow == _flow) return;

    final currentPage = _page;

    setState(() {
      _flow = flow;
      _startPage = currentPage;
      _showSearch = false;
      _searchController.clear();
      _params = null;
      _createViewer();
    });

    _prefs?.setString(_flowPref, flow.name);
  }

  void _toggleChrome() => setState(() => _showChrome = !_showChrome);

  void _fullScreen() {
    if (widget.onFullScreen != null) {
      widget.onFullScreen!();
    } else {
      setState(() => _showChrome = false);
    }
  }

  // ---------------------------------------------------------------------------
  // Viewer layout
  // ---------------------------------------------------------------------------

  static PdfPageLayout _horizontalLayout(
    List<PdfPage> pages,
    PdfViewerParams params,
  ) {
    final height =
        pages.fold<double>(
          0,
          (maxHeight, page) => math.max(maxHeight, page.height),
        ) +
        params.margin * 2;

    final rects = <Rect>[];
    var x = params.margin;

    for (final page in pages) {
      rects.add(
        Rect.fromLTWH(x, (height - page.height) / 2, page.width, page.height),
      );
      x += page.width + params.margin;
    }

    return PdfPageLayout(pageLayouts: rects, documentSize: Size(x, height));
  }

  Color get _canvas => switch (_theme) {
    PdfReadTheme.normal => const Color(0xFFE5E7EB),
    PdfReadTheme.night => const Color(0xFF151515),
    PdfReadTheme.eyeCare => const Color(0xFFD9D0B7),
  };

  ColorFilter? get _pageFilter => switch (_theme) {
    PdfReadTheme.normal => null,
    PdfReadTheme.night => const ColorFilter.matrix([
      -0.87,
      0,
      0,
      0,
      230,
      0,
      -0.87,
      0,
      0,
      230,
      0,
      0,
      -0.87,
      0,
      230,
      0,
      0,
      0,
      1,
      0,
    ]),
    PdfReadTheme.eyeCare => const ColorFilter.matrix([
      0.96,
      0,
      0,
      0,
      0,
      0,
      0.90,
      0,
      0,
      0,
      0,
      0,
      0.72,
      0,
      0,
      0,
      0,
      0,
      1,
      0,
    ]),
  };

  PdfViewerParams _buildParams() {
    final vertical = _flow == PdfPageFlow.vertical;

    return PdfViewerParams(
      backgroundColor: Colors.transparent,
      layoutPages: vertical ? null : _horizontalLayout,
      scrollHorizontallyByMouseWheel: !vertical,
      pageDropShadow: const BoxShadow(
        color: Color(0x35000000),
        blurRadius: 7,
        offset: Offset(0, 2),
      ),
      onViewerReady: _onReady,
      onPageChanged: _onPageChanged,
      onGeneralTap: _onViewerTap,
      pagePaintCallbacks: [
        _paintHighlights,
        (canvas, pageRect, page) =>
            _searcher?.pageTextMatchPaintCallback(canvas, pageRect, page),
      ],
      textSelectionParams: PdfTextSelectionParams(
        // Mouse too, not only touch, so Highlight shows after a drag on a PC.
        showContextMenuAutomatically: true,
        onTextSelectionChange: _onSelectionChange,
      ),
      customizeContextMenuItems: _customizeMenu,
      onKey: _onKey,
      linkHandlerParams: PdfLinkHandlerParams(onLinkTap: _onLink),
      viewerOverlayBuilder: _overlays,
    );
  }

  bool _onViewerTap(
    BuildContext context,
    PdfViewerController controller,
    PdfViewerGeneralTapHandlerDetails details,
  ) {
    if (_touchPlatform &&
        details.type == PdfViewerGeneralTapType.tap &&
        details.tapOn != PdfViewerPart.selectedText) {
      _toggleChrome();
    }
    return false;
  }

  void _onLink(PdfLink link) {
    if (link.dest != null) _viewer.goToDest(link.dest);
  }

  List<Widget> _overlays(
    BuildContext context,
    Size size,
    PdfViewerHandleLinkTap handleLinkTap,
  ) {
    final vertical = _flow == PdfPageFlow.vertical;

    return [
      PdfViewerScrollThumb(
        controller: _viewer,
        orientation: vertical
            ? ScrollbarOrientation.right
            : ScrollbarOrientation.bottom,
        thumbSize: vertical ? const Size(48, 28) : const Size(58, 28),
        thumbBuilder: (context, thumbSize, pageNumber, controller) {
          return _PageThumb(label: '${pageNumber ?? ''}');
        },
      ),
    ];
  }

  // ---------------------------------------------------------------------------
  // Screen
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: _canvas,
      appBar: !widget.embedded && _showChrome
          ? StudioAppBar(
              title: widget.title,
              icon: Icons.picture_as_pdf_rounded,
              iconColor: AppColors.accentOrange,
            )
          : null,
      drawer: _pageCount == 0
          ? null
          : _PdfSidebar(
              document: _viewer.isReady ? _viewer.document : null,
              pageCount: _pageCount,
              currentPage: _page,
              outline: _outline,
              highlights: _highlights,
              onRemoveHighlight: _removeHighlight,
              onPageSelected: (page) {
                Navigator.pop(context);
                _goToPage(page);
              },
              onDestinationSelected: (destination) {
                Navigator.pop(context);
                _viewer.goToDest(destination);
              },
            ),
      body: Column(
        children: [
          if (_showChrome)
            _PdfToolbar(
              ready: _ready,
              page: _page,
              pageCount: _pageCount,
              pageController: _pageController,
              pageFocus: _pageFocus,
              theme: _theme,
              flow: _flow,
              onContents: () => _scaffoldKey.currentState?.openDrawer(),
              onZoomOut: () => _viewer.zoomDown(),
              onZoomIn: () => _viewer.zoomUp(),
              onFitWidth: _fitWidth,
              onFitPage: _fitPage,
              onPageSubmitted: _submitPage,
              onSearch: _openSearch,
              onTheme: _setTheme,
              onFlow: _setFlow,
              onFullScreen: _fullScreen,
            ),
          if (_showChrome && _showSearch && _searcher != null)
            _PdfSearchBar(
              controller: _searchController,
              focusNode: _searchFocus,
              searcher: _searcher!,
              onChanged: _search,
              onClose: _closeSearch,
            ),
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(child: _buildViewer()),
                if (!_showChrome)
                  Positioned(
                    top: 12,
                    right: 12,
                    child: SafeArea(
                      child: Material(
                        elevation: 3,
                        borderRadius: BorderRadius.circular(12),
                        child: IconButton(
                          tooltip: tr(context, 'Show controls'),
                          onPressed: _toggleChrome,
                          icon: const Icon(Icons.keyboard_arrow_down_rounded),
                        ),
                      ),
                    ),
                  ),
                if (_showChrome && _pageCount > 0)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: _PdfStatusBar(
                      page: _page,
                      pageCount: _pageCount,
                      theme: _theme,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildViewer() {
    final filter = _pageFilter;
    final viewer = PdfViewer.file(
      widget.path,
      key: ValueKey('${widget.path}|$_flow'),
      controller: _viewer,
      // The page count isn't known until the viewer is ready, so clamping
      // against it here would always open on page 1.
      initialPageNumber: math.max(_startPage, 1),
      params: _params ??= _buildParams(),
    );

    return filter == null
        ? viewer
        : ColorFiltered(colorFilter: filter, child: viewer);
  }
}

// =============================================================================
// TOOLBAR
// =============================================================================

class _PdfToolbar extends StatelessWidget {
  const _PdfToolbar({
    required this.ready,
    required this.page,
    required this.pageCount,
    required this.pageController,
    required this.pageFocus,
    required this.theme,
    required this.flow,
    required this.onContents,
    required this.onZoomOut,
    required this.onZoomIn,
    required this.onFitWidth,
    required this.onFitPage,
    required this.onPageSubmitted,
    required this.onSearch,
    required this.onTheme,
    required this.onFlow,
    required this.onFullScreen,
  });

  final bool ready;
  final int page;
  final int pageCount;
  final TextEditingController pageController;
  final FocusNode pageFocus;
  final PdfReadTheme theme;
  final PdfPageFlow flow;
  final VoidCallback onContents;
  final VoidCallback onZoomOut;
  final VoidCallback onZoomIn;
  final VoidCallback onFitWidth;
  final VoidCallback onFitPage;
  final ValueChanged<String> onPageSubmitted;
  final VoidCallback onSearch;
  final ValueChanged<PdfReadTheme> onTheme;
  final ValueChanged<PdfPageFlow> onFlow;
  final VoidCallback onFullScreen;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);

    Widget button(String tip, IconData icon, VoidCallback? action) {
      return IconButton(
        tooltip: tr(context, tip),
        visualDensity: VisualDensity.compact,
        onPressed: action,
        icon: Icon(icon, size: 21),
      );
    }

    Widget divider() => Container(
      width: 1,
      height: 24,
      margin: const EdgeInsets.symmetric(horizontal: 5),
      color: colors.border,
    );

    final children = <Widget>[
      button('Contents', Icons.menu_rounded, ready ? onContents : null),
      divider(),
      button('Zoom out', Icons.remove_rounded, ready ? onZoomOut : null),
      button('Zoom in', Icons.add_rounded, ready ? onZoomIn : null),
      button('Fit width', Icons.fit_screen_outlined, ready ? onFitWidth : null),
      button(
        'Whole page',
        Icons.crop_portrait_rounded,
        ready ? onFitPage : null,
      ),
      divider(),
      SizedBox(
        width: 58,
        height: 34,
        child: TextField(
          controller: pageController,
          focusNode: pageFocus,
          enabled: ready,
          textAlign: TextAlign.center,
          keyboardType: TextInputType.number,
          textInputAction: TextInputAction.go,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          style: const TextStyle(fontSize: 13),
          decoration: const InputDecoration(
            isDense: true,
            contentPadding: EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            border: OutlineInputBorder(),
          ),
          onSubmitted: onPageSubmitted,
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7),
        child: Text(
          trFill(context, 'of {n}', {'n': ready ? '$pageCount' : '–'}),
          style: TextStyle(color: colors.textSecondary, fontSize: 13),
        ),
      ),
      divider(),
      _ViewMenu(theme: theme, flow: flow, onTheme: onTheme, onFlow: onFlow),
      const Spacer(),
      button('Search', Icons.search_rounded, ready ? onSearch : null),
      divider(),
      button('Full screen', Icons.open_in_full_rounded, onFullScreen),
    ];

    return Material(
      color: colors.surface,
      elevation: 2,
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: 50,
          child: LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth >= 720) {
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Row(children: children),
                );
              }

              return SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Row(
                  children: children.where((w) => w is! Spacer).toList(),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// SEARCH BAR
// =============================================================================

class _PdfSearchBar extends StatelessWidget {
  const _PdfSearchBar({
    required this.controller,
    required this.focusNode,
    required this.searcher,
    required this.onChanged,
    required this.onClose,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final PdfTextSearcher searcher;
  final ValueChanged<String> onChanged;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final status = searcher.isSearching
        ? '…'
        : controller.text.isEmpty
        ? ''
        : searcher.matches.isEmpty
        ? '0'
        : '${(searcher.currentIndex ?? 0) + 1} / ${searcher.matches.length}';

    return Material(
      color: colors.surface,
      elevation: 2,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 3, 4, 3),
          child: Row(
            children: [
              const Icon(Icons.search_rounded, size: 20),
              const SizedBox(width: 6),
              Expanded(
                child: TextField(
                  controller: controller,
                  focusNode: focusNode,
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    hintText: tr(context, 'Find in document'),
                    border: InputBorder.none,
                    isDense: true,
                  ),
                  onChanged: onChanged,
                  onSubmitted: (_) => searcher.goToNextMatch(),
                ),
              ),
              if (searcher.isSearching)
                SizedBox(
                  width: 17,
                  height: 17,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    value: searcher.searchProgress,
                  ),
                ),
              if (status.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    status,
                    style: TextStyle(color: colors.textSecondary, fontSize: 12),
                  ),
                ),
              IconButton(
                tooltip: tr(context, 'Previous'),
                visualDensity: VisualDensity.compact,
                onPressed: searcher.hasMatches ? searcher.goToPrevMatch : null,
                icon: const Icon(Icons.keyboard_arrow_up_rounded),
              ),
              IconButton(
                tooltip: tr(context, 'Next'),
                visualDensity: VisualDensity.compact,
                onPressed: searcher.hasMatches ? searcher.goToNextMatch : null,
                icon: const Icon(Icons.keyboard_arrow_down_rounded),
              ),
              IconButton(
                tooltip: tr(context, 'Close'),
                visualDensity: VisualDensity.compact,
                onPressed: onClose,
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// VIEW MENU
// =============================================================================

class _ViewMenu extends StatelessWidget {
  const _ViewMenu({
    required this.theme,
    required this.flow,
    required this.onTheme,
    required this.onFlow,
  });

  final PdfReadTheme theme;
  final PdfPageFlow flow;
  final ValueChanged<PdfReadTheme> onTheme;
  final ValueChanged<PdfPageFlow> onFlow;

  @override
  Widget build(BuildContext context) {
    PopupMenuItem<VoidCallback> item(
      IconData icon,
      String label,
      bool selected,
      VoidCallback action,
    ) {
      return PopupMenuItem(
        value: action,
        child: Row(
          children: [
            Icon(icon, size: 19),
            const SizedBox(width: 12),
            Expanded(child: Text(label)),
            if (selected) const Icon(Icons.check_rounded, size: 18),
          ],
        ),
      );
    }

    return PopupMenuButton<VoidCallback>(
      tooltip: tr(context, 'View'),
      icon: const Icon(Icons.chrome_reader_mode_outlined, size: 21),
      onSelected: (action) => action(),
      itemBuilder: (_) => [
        item(
          Icons.swap_vert_rounded,
          tr(context, 'Vertical'),
          flow == PdfPageFlow.vertical,
          () => onFlow(PdfPageFlow.vertical),
        ),
        item(
          Icons.swap_horiz_rounded,
          tr(context, 'Horizontal'),
          flow == PdfPageFlow.horizontal,
          () => onFlow(PdfPageFlow.horizontal),
        ),
        const PopupMenuDivider(),
        item(
          Icons.light_mode_outlined,
          tr(context, 'Day'),
          theme == PdfReadTheme.normal,
          () => onTheme(PdfReadTheme.normal),
        ),
        item(
          Icons.dark_mode_outlined,
          tr(context, 'Night'),
          theme == PdfReadTheme.night,
          () => onTheme(PdfReadTheme.night),
        ),
        item(
          Icons.remove_red_eye_outlined,
          tr(context, 'Eye care'),
          theme == PdfReadTheme.eyeCare,
          () => onTheme(PdfReadTheme.eyeCare),
        ),
      ],
    );
  }
}

// =============================================================================
// SIDEBAR
// =============================================================================

class _PdfSidebar extends StatelessWidget {
  const _PdfSidebar({
    required this.document,
    required this.pageCount,
    required this.currentPage,
    required this.outline,
    required this.highlights,
    required this.onRemoveHighlight,
    required this.onPageSelected,
    required this.onDestinationSelected,
  });

  final PdfDocument? document;
  final int pageCount;
  final int currentPage;
  final List<PdfOutlineNode> outline;
  final List<PdfHighlight> highlights;
  final ValueChanged<PdfHighlight> onRemoveHighlight;
  final ValueChanged<int> onPageSelected;
  final ValueChanged<PdfDest?> onDestinationSelected;

  @override
  Widget build(BuildContext context) {
    return Drawer(
      width: 320,
      child: SafeArea(
        child: DefaultTabController(
          length: 3,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 12, 10),
                child: Row(
                  children: [
                    const Icon(Icons.picture_as_pdf_rounded),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        tr(context, 'Document'),
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ),
                    Text(
                      '$pageCount',
                      style: TextStyle(
                        color: AppColors.of(context).textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              TabBar(
                tabs: [
                  Tab(
                    icon: const Icon(Icons.grid_view_rounded),
                    text: tr(context, 'Pages'),
                  ),
                  Tab(
                    icon: const Icon(Icons.list_alt_rounded),
                    text: tr(context, 'Contents'),
                  ),
                  Tab(
                    icon: const Icon(Icons.border_color_rounded),
                    text: tr(context, 'Highlights'),
                  ),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    _ThumbnailList(
                      document: document,
                      pageCount: pageCount,
                      currentPage: currentPage,
                      onPageSelected: onPageSelected,
                    ),
                    _OutlineList(
                      outline: outline,
                      onDestinationSelected: onDestinationSelected,
                    ),
                    _HighlightList(
                      highlights: highlights,
                      onPageSelected: onPageSelected,
                      onRemove: onRemoveHighlight,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ThumbnailList extends StatelessWidget {
  const _ThumbnailList({
    required this.document,
    required this.pageCount,
    required this.currentPage,
    required this.onPageSelected,
  });

  final PdfDocument? document;
  final int pageCount;
  final int currentPage;
  final ValueChanged<int> onPageSelected;

  @override
  Widget build(BuildContext context) {
    final doc = document;
    if (doc == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      itemCount: pageCount,
      itemBuilder: (context, index) {
        final page = index + 1;
        final selected = page == currentPage;

        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => onPageSelected(page),
            child: Container(
              padding: const EdgeInsets.all(5),
              decoration: BoxDecoration(
                color: selected
                    ? AppColors.primary.withValues(alpha: 0.08)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: selected ? AppColors.primary : Colors.black12,
                  width: selected ? 2 : 1,
                ),
              ),
              child: Column(
                children: [
                  AspectRatio(
                    aspectRatio: 0.70,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: PdfPageView(
                        document: doc,
                        pageNumber: page,
                        maximumDpi: 48,
                        backgroundColor: Colors.white,
                      ),
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    '$page',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                      color: selected ? AppColors.primary : null,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _OutlineList extends StatelessWidget {
  const _OutlineList({
    required this.outline,
    required this.onDestinationSelected,
  });

  final List<PdfOutlineNode> outline;
  final ValueChanged<PdfDest?> onDestinationSelected;

  @override
  Widget build(BuildContext context) {
    if (outline.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            tr(context, 'No contents available'),
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.of(context).textSecondary),
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [for (final node in outline) ..._tiles(context, node, 0)],
    );
  }

  Iterable<Widget> _tiles(
    BuildContext context,
    PdfOutlineNode node,
    int depth,
  ) sync* {
    yield ListTile(
      dense: true,
      contentPadding: EdgeInsets.only(left: 16 + depth * 16.0, right: 12),
      title: Text(node.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: node.dest == null
          ? null
          : Text(
              '${node.dest!.pageNumber}',
              style: TextStyle(
                color: AppColors.of(context).textSecondary,
                fontSize: 12,
              ),
            ),
      onTap: node.dest == null ? null : () => onDestinationSelected(node.dest),
    );

    for (final child in node.children) {
      yield* _tiles(context, child, depth + 1);
    }
  }
}

class _HighlightList extends StatelessWidget {
  const _HighlightList({
    required this.highlights,
    required this.onPageSelected,
    required this.onRemove,
  });

  final List<PdfHighlight> highlights;
  final ValueChanged<int> onPageSelected;
  final ValueChanged<PdfHighlight> onRemove;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    if (highlights.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            tr(context, 'No highlights'),
            textAlign: TextAlign.center,
            style: TextStyle(color: colors.textSecondary),
          ),
        ),
      );
    }

    final sorted = [...highlights]..sort((a, b) => a.page.compareTo(b.page));
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        for (final h in sorted)
          ListTile(
            dense: true,
            leading: Container(
              width: 4,
              height: 32,
              color: const Color(0xFFFFEB3B),
            ),
            title: Text(
              h.text.isEmpty ? '…' : h.text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(trFill(context, 'Page {n}', {'n': '${h.page}'})),
            trailing: IconButton(
              tooltip: tr(context, 'Remove highlight'),
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.close_rounded, size: 18),
              onPressed: () => onRemove(h),
            ),
            onTap: () => onPageSelected(h.page),
          ),
      ],
    );
  }
}

// =============================================================================
// STATUS / SCROLL THUMB
// =============================================================================

class _PdfStatusBar extends StatelessWidget {
  const _PdfStatusBar({
    required this.page,
    required this.pageCount,
    required this.theme,
  });

  final int page;
  final int pageCount;
  final PdfReadTheme theme;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);

    return IgnorePointer(
      child: Container(
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: colors.surface.withValues(alpha: 0.94),
          border: Border(top: BorderSide(color: colors.border)),
        ),
        child: Row(
          children: [
            Icon(
              Icons.menu_book_rounded,
              size: 14,
              color: colors.textSecondary,
            ),
            const SizedBox(width: 6),
            Text(
              '$page / $pageCount',
              style: TextStyle(
                color: colors.textSecondary,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
            const Spacer(),
            Text(switch (theme) {
              PdfReadTheme.normal => 'Day',
              PdfReadTheme.night => 'Night',
              PdfReadTheme.eyeCare => 'Eye care',
            }, style: TextStyle(color: colors.textSecondary, fontSize: 11)),
          ],
        ),
      ),
    );
  }
}

class _PageThumb extends StatelessWidget {
  const _PageThumb({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
