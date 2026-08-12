import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../core/network/artwork_cache.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../../core/app_version.dart';
import '../../data/genre_pool.dart';
import '../../data/models/album.dart';
import '../../data/models/album_details.dart';
import '../../data/models/rating.dart';
import '../../data/remote/coverart_client.dart';
import '../../data/repositories/export_repository.dart';
import '../../data/repositories/update_check_repository.dart';
import '../rated_albums/rated_albums_screen.dart';
import '../settings/settings_screen.dart';
import 'album_details_sheet.dart';
import 'discovery_controller.dart';

class DiscoveryScreen extends StatefulWidget {
  final DiscoveryController controller;

  const DiscoveryScreen({super.key, required this.controller});

  @override
  State<DiscoveryScreen> createState() => _DiscoveryScreenState();
}

// The main card (art + labels + buttons) sits on top of a hidden background
// menu, full-screen at rest. A vertical swipe past a small threshold is a
// trigger, not a scrub — the card doesn't move with the finger at all; on
// release it plays one fixed open/close animation to whichever end state
// the swipe direction indicated. Tapping the card while open, or swiping
// down on the exposed background, closes it the same way.
class _DiscoveryScreenState extends State<DiscoveryScreen>
    with TickerProviderStateMixin {
  double _menuDragAccum = 0;
  double _cardDragAccum = 0;
  double _artworkHorizontalDragAccum = 0;
  double _artworkVerticalDragAccum = 0;
  double _contentVerticalDragAccum = 0;
  bool _trackingMenuVerticalDrag = false;
  bool _trackingCardVerticalDrag = false;
  bool _trackingArtworkHorizontalDrag = false;
  late AnimationController _liftController;
  late AnimationController _searchController;
  late AnimationController _skipController;
  bool _skipAnimating = false;
  String? _skipAlbumMbid;
  bool _searchOpen = false;
  bool _detailsSheetOpen = false;
  bool _searching = false;
  bool _onboardingActive = false;
  bool _menuOpenState = false;
  DateTime? _lastBackPress;
  DateTime? _lastBackHandling;
  Timer? _searchDebounce;
  int _searchRequestId = 0;
  List<Map<String, dynamic>> _searchResults = [];
  final Map<String, Future<AlbumDetails>> _albumDetailsFutures = {};
  final _searchFieldController = TextEditingController();
  final _searchFocusNode = FocusNode();

  // Lets `_autoOpenDefaultMenuItem` push directly onto the menu's nested
  // Navigator from outside `_MenuHomePage`, to auto-open the configured
  // default item ahead of the menu ever being revealed.
  final _menuNavigatorKey = GlobalKey<NavigatorState>();

  static const _snapDuration = Duration(milliseconds: 600);
  static const _snapCurve = Curves.easeInOutCubicEmphasized;
  static const _dragTriggerDistance = 40.0;
  static const _searchFadeDuration = Duration(milliseconds: 320);
  static const _contentFadeDuration = Duration(milliseconds: 280);

  @override
  void initState() {
    super.initState();
    // Keep a direct platform fallback for Android devices whose predictive
    // back dispatcher bypasses PopScope when the app uses a nested Navigator.
    // The duplicate-event guard in _handleSystemBack coalesces this with the
    // framework callback when both are delivered for one gesture.
    SystemChannels.navigation.setMethodCallHandler(_handleNavigationMessage);
    _liftController = AnimationController(vsync: this, duration: _snapDuration);
    _liftController.addListener(_trackMenuOpenState);
    _searchController =
        AnimationController(vsync: this, duration: _searchFadeDuration);
    _skipController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    );
    // The menu's Navigator is always mounted (see `build`'s Stack — it's
    // just visually covered by the card, same cross-fade technique as the
    // search overlay), so the default page can be pushed while it's still
    // off-screen instead of waiting for the lift animation to finish. That
    // way there's nothing left to animate by the time the reveal makes it
    // visible — no secondary slide-in. Deferred one frame so
    // `_menuNavigatorKey.currentState` is guaranteed mounted.
    WidgetsBinding.instance.addPostFrameCallback((_) => _initializeStartup());
  }

  Future<void> _initializeStartup() async {
    if (!mounted) return;
    unawaited(_runAutomaticBackup());
    unawaited(_runAutomaticUpdateCheck());
    if (widget.controller.needsOnboarding()) {
      _onboardingActive = true;
      final navigator = _menuNavigatorKey.currentState;
      if (navigator != null && !navigator.canPop()) {
        final page = navigator.push(CupertinoPageRoute(
          builder: (context) => _SwipeBackPop(
            child: _GenrePickerPage(
              controller: widget.controller,
              onboarding: true,
              onDone: _finishOnboarding,
            ),
          ),
        ));
        _liftController.animateTo(1,
            duration: _snapDuration, curve: _snapCurve);
        await page;
      }
      if (mounted) _onboardingActive = false;
      return;
    }
    widget.controller.loadNext();
    _autoOpenDefaultMenuItem();
  }

  Future<void> _finishOnboarding() async {
    if (widget.controller.likedGenres().isEmpty) return;
    await widget.controller.loadNext();
    if (!mounted) return;
    if (_menuNavigatorKey.currentState?.canPop() ?? false) {
      _menuNavigatorKey.currentState!.pop();
    }
    _liftController.animateTo(0, duration: _snapDuration, curve: _snapCurve);
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    SystemChannels.navigation.setMethodCallHandler(null);
    _liftController.removeListener(_trackMenuOpenState);
    _liftController.dispose();
    _searchController.dispose();
    _skipController.dispose();
    _searchFieldController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  Future<void> _handleNavigationMessage(MethodCall call) async {
    if (call.method == 'popRoute') {
      _handleSystemBack();
    }
  }

  void _trackMenuOpenState() {
    _menuOpenState = _liftController.value > 0.01;
  }

  // Pushes the configured default menu item once, ahead of the menu ever
  // being revealed (see `initState`). Guarded by `canPop()` — if something
  // is already pushed (shouldn't happen this early, but keeps the guard
  // that existed before this ran on every open), don't push again.
  void _autoOpenDefaultMenuItem() {
    if (_onboardingActive) return;
    final navigator = _menuNavigatorKey.currentState;
    if (navigator == null || navigator.canPop()) return;

    final defaultItem = widget.controller.settings.defaultOpenedMenuItem();
    if (defaultItem == null) return;

    final page = switch (defaultItem) {
      'Liked genres' => _GenrePickerPage(controller: widget.controller),
      'Rated albums' => RatedAlbumsPage(
          ratingRepository: widget.controller.ratings,
          albumRepository: widget.controller.albums,
          savedFilterRepository: widget.controller.savedFilters,
          settings: widget.controller.settings,
          notes: widget.controller.notes,
          onAlbumTap: _openRatedAlbum,
        ),
      'Settings' => SettingsPage(
          settings: widget.controller.settings,
          onResetSkipPenalties: widget.controller.resetSkipPenalties,
          onClearArtworkCache: _clearArtworkCache,
          onClearAlbumCache: _clearAlbumCache,
          onBackup: _backupRatings,
          onPickBackupFolder: _pickBackupFolder,
          onCheckForUpdate: () =>
              widget.controller.checkForUpdate(force: true),
          onRefreshRatedAlbumsMetadata:
              widget.controller.refreshRatedAlbumsMetadata),
      _ => null,
    };
    if (page == null) return;

    navigator.push(
      CupertinoPageRoute(builder: (context) => _SwipeBackPop(child: page)),
    );
  }

  // Listener (not GestureDetector) so this tracks raw pointer movement
  // regardless of what any descendant Scrollable/GestureDetector does with
  // the same pointer — a vertical drag that starts over an inner scrollable
  // (e.g. RatedAlbumsPage's list, the genre picker's Wrap) still gets
  // tracked here in parallel instead of losing the gesture-arena fight to
  // the scroll, which is what a GestureDetector would do.
  bool get _menuInnerPageShowing =>
      _menuNavigatorKey.currentState?.canPop() ?? false;

  void _onDragStart(PointerDownEvent event) {
    // Inner pages own vertical gestures for their scroll views and the
    // horizontal swipe-back wrapper. Do not move the discovery card beneath.
    _menuDragAccum = 0;
    // Once a level-2 menu page is visible, its lists/grids own all vertical
    // drags. Never let the hidden discovery card react to their scrolling.
    _trackingMenuVerticalDrag = !_menuInnerPageShowing;
  }

  void _onDragUpdate(PointerMoveEvent event) {
    if (!_trackingMenuVerticalDrag) return;
    _menuDragAccum += event.delta.dy;
  }

  // Background: swipe up has nothing further to open, so only the
  // downward/close direction actually does anything here.
  void _onDragEnd(PointerUpEvent event) {
    if (!_trackingMenuVerticalDrag) return;
    _trackingMenuVerticalDrag = false;
    if (_menuDragAccum <= -_dragTriggerDistance) {
      _liftController.animateTo(1, duration: _snapDuration, curve: _snapCurve);
    } else if (_menuDragAccum >= _dragTriggerDistance) {
      _liftController.animateTo(0, duration: _snapDuration, curve: _snapCurve);
    }
    // Otherwise: too small to count as a real swipe — the card never moved
    // during the drag, so there's nothing to snap back from.
  }

  // Card: swiping down means something different depending on state —
  // closed already means there's nowhere further down to go, so that's
  // repurposed to open search instead.
  //
  // The card's Listener still wraps the search overlay so it can observe the
  // pointer without competing in the gesture arena, but search results own
  // vertical movement. Search is closed by the close control or system back,
  // never by swiping the result list.
  void _onCardDragStart(PointerDownEvent event) {
    if (_skipAnimating) return;
    _cardDragAccum = 0;
    _trackingCardVerticalDrag = true;
  }

  void _onCardDragUpdate(PointerMoveEvent event) {
    if (!_trackingCardVerticalDrag) return;
    _cardDragAccum += event.delta.dy;
  }

  void _onCardDragEnd(PointerUpEvent event) {
    if (!_trackingCardVerticalDrag) return;
    _trackingCardVerticalDrag = false;
    if (_searchOpen) return;
    final isOpen = _liftController.value > 0.5;
    if (_cardDragAccum <= -_dragTriggerDistance && !isOpen) {
      _liftController.animateTo(1, duration: _snapDuration, curve: _snapCurve);
    } else if (_cardDragAccum >= _dragTriggerDistance) {
      // _searchOpen is already excluded by the early return above.
      if (isOpen) {
        _close();
      } else {
        _openSearch();
      }
    }
  }

  void _onContentDragStart(PointerDownEvent event) {
    _contentVerticalDragAccum = 0;
  }

  void _onContentDragUpdate(PointerMoveEvent event) {
    _contentVerticalDragAccum += event.delta.dy;
  }

  void _onContentDragEnd(PointerUpEvent event) {
    if (_contentVerticalDragAccum < _dragTriggerDistance || _searchOpen) {
      return;
    }
    if (_liftController.value > 0.5) {
      _close();
    } else {
      _openSearch();
    }
  }

  // Skipping is deliberately limited to the artwork hit area. Keeping this
  // separate from the card listener prevents buttons and metadata from
  // accidentally discarding the current album during a horizontal drag.
  void _onArtworkDragStart(PointerDownEvent event) {
    if (_skipAnimating) return;
    // Artwork participates in the card's vertical up/down gestures as well
    // as its own horizontal left-skip gesture.
    _artworkHorizontalDragAccum = 0;
    _artworkVerticalDragAccum = 0;
    _trackingArtworkHorizontalDrag = true;
  }

  void _onArtworkDragUpdate(PointerMoveEvent event) {
    if (!_trackingArtworkHorizontalDrag) return;
    _artworkHorizontalDragAccum += event.delta.dx;
    _artworkVerticalDragAccum += event.delta.dy;
  }

  void _onArtworkDragEnd(PointerUpEvent event) {
    if (!_trackingArtworkHorizontalDrag) return;
    _trackingArtworkHorizontalDrag = false;
    if (_searchOpen || _skipAnimating) return;
    if (_artworkHorizontalDragAccum <= -_dragTriggerDistance &&
        _artworkHorizontalDragAccum.abs() > _cardDragAccum.abs()) {
      unawaited(_animateAlbumSkip());
      return;
    }
    if (_artworkVerticalDragAccum.abs() >= _dragTriggerDistance &&
        _artworkVerticalDragAccum.abs() > _artworkHorizontalDragAccum.abs()) {
      final isOpen = _liftController.value > 0.5;
      if (_artworkVerticalDragAccum <= -_dragTriggerDistance && !isOpen) {
        _liftController.animateTo(1,
            duration: _snapDuration, curve: _snapCurve);
      } else if (_artworkVerticalDragAccum >= _dragTriggerDistance) {
        if (isOpen) {
          _close();
        } else {
          _openSearch();
        }
      }
    }
  }

  Future<void> _animateAlbumSkip({bool fromButton = false}) async {
    if (_skipAnimating || widget.controller.currentAlbum == null) return;
    _skipAnimating = true;
    _skipAlbumMbid = widget.controller.currentAlbum!.mbid;
    try {
      await _skipController.forward(from: 0);
      if (mounted) {
        if (fromButton) {
          await widget.controller.skipButton();
        } else {
          await widget.controller.skip();
        }
      }
      await Future<void>.delayed(_contentFadeDuration);
    } finally {
      if (mounted) {
        _skipController.reset();
        _skipAlbumMbid = null;
        _skipAnimating = false;
      }
    }
  }

  // Always safe to call regardless of current state.
  void _close() {
    _menuOpenState = false;
    if (_liftController.value > 0.01) {
      _liftController.animateTo(0, duration: _snapDuration, curve: _snapCurve);
    }
  }

  /// Returns a journal selection to the focused discovery card before loading
  /// it, so the selected album is visible instead of remaining behind the
  /// raised menu.
  Future<void> _openRatedAlbum(String mbid) async {
    _close();
    await widget.controller.startFromSearchResult(mbid);
  }

  void _openSearch() {
    setState(() => _searchOpen = true);
    _searchController.animateTo(1,
        duration: _searchFadeDuration, curve: Curves.easeOutCubic);
    // Explicit request rather than the TextField's `autofocus`: the search
    // overlay's Opacity/IgnorePointer subtree is conditionally excluded from
    // the Stack while fully closed (see `_body`), but this FocusNode is a
    // field on this State, not the overlay subtree, so requesting focus
    // here works the same way regardless of whether that subtree happens to
    // remount or merely rebuild.
    _searchFocusNode.requestFocus();
  }

  void _closeSearch() {
    _searchDebounce?.cancel();
    _searchRequestId++;
    if (_searchOpen) {
      setState(() => _searchOpen = false);
    }
    // Drop focus immediately (not deferred to whenComplete) so the keyboard
    // dismisses as part of the close animation, and no stale focus request
    // lingers into the next open.
    _searchFocusNode.unfocus();
    _searchController
        .animateTo(0, duration: _searchFadeDuration, curve: Curves.easeOutCubic)
        .whenComplete(() {
      if (!mounted) return;
      setState(() {
        _searchResults = [];
        _searchFieldController.clear();
      });
    });
  }

  void _onSearchChanged(DiscoveryController controller, String query) {
    _searchDebounce?.cancel();
    final requestId = ++_searchRequestId;
    final trimmed = query.trim();
    if (trimmed.length < 2) {
      setState(() {
        _searching = false;
        _searchResults = [];
      });
      return;
    }
    final local = controller.searchCachedAlbums(trimmed);
    setState(() {
      _searching = true;
      _searchResults = local;
    });
    _searchDebounce = Timer(const Duration(milliseconds: 400), () {
      _runSearch(controller, trimmed, requestId: requestId);
    });
  }

  Future<void> _runSearch(DiscoveryController controller, String query,
      {int? requestId}) async {
    if (query.trim().isEmpty) return;
    final currentRequest = requestId ?? ++_searchRequestId;
    _searchDebounce?.cancel();
    setState(() => _searching = true);
    final results = await controller.searchAlbums(query);
    if (!mounted || currentRequest != _searchRequestId) return;
    final merged = <String, Map<String, dynamic>>{};
    for (final result in [..._searchResults, ...results]) {
      final id = result['id'] as String?;
      if (id != null) merged[id] = result;
    }
    setState(() {
      _searching = false;
      _searchResults = merged.values.toList();
    });
  }

  Future<void> _pickSearchResult(
      DiscoveryController controller, String mbid) async {
    _closeSearch();
    await controller.startFromSearchResult(mbid);
  }

  Future<void> _clearArtworkCache() async {
    await ArtworkCache.manager.emptyCache();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Artwork cache cleared')),
      );
    }
  }

  void _clearAlbumCache() {
    widget.controller.albums.clearUnratedCache();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Un-rated album cache cleared')),
    );
  }

  Future<void> _backupRatings() async {
    final json = await ExportRepository(
      widget.controller.ratings,
      widget.controller.albums,
    ).toJson();
    final directory = await getTemporaryDirectory();
    final file = File('${directory.path}/cairn_ratings.json');
    await file.writeAsString(json);
    await Share.shareXFiles(
      [XFile(file.path, mimeType: 'application/json')],
      text: 'Cairn ratings backup',
    );
  }

  // TEMPORARY STUB: file_picker is disabled project-wide right now because
  // its Android module is incompatible with this project's AGP 9.0.1/Kotlin
  // 2.3.20 toolchain (file_picker 8.1.7 hardcodes compileSdk 34 against a
  // transitive dependency that now requires 36+; 11.0.3's Kotlin source
  // isn't even compiled by this toolchain; 12.0.0-beta.7 conflicts with
  // share_plus's win32 constraint) — see pubspec.yaml. Revert to
  // `FilePicker.platform.getDirectoryPath(dialogTitle: 'Choose Cairn backup
  // folder')` (and restore the `file_picker` dependency + the import at the
  // top of this file) once that's resolved.
  Future<String?> _pickBackupFolder() async => null;

  Future<void> _runAutomaticBackup() async {
    final settings = widget.controller.settings;
    final folder = settings.backupFolderPath();
    if (!settings.autoBackupsEnabled() ||
        settings.backupConsent() != 'accepted' ||
        folder == null ||
        !widget.controller.backups
            .isDue(DateTime.now(), settings.lastBackupAt())) {
      return;
    }
    try {
      await widget.controller.backups.createWeeklyBackup(folder);
      settings.setLastBackupAt(DateTime.now());
    } catch (_) {
      // A failed backup must not alter the primary database or its timestamp.
    }
  }

  // Silent unless an update is actually found — no-op both when the check
  // isn't due yet and when it ran but found nothing newer. A failed check
  // (network error, etc.) is also silent here; only a manual check (Settings
  // button, tapping the version number) reports failure, since a background
  // weekly check failing isn't something the user needs interrupted for.
  Future<void> _runAutomaticUpdateCheck() async {
    final (succeeded, newerVersion) = await widget.controller.checkForUpdate();
    if (!mounted || !succeeded || newerVersion == null) return;
    _showUpdateAvailableSnackBar(newerVersion);
  }

  void _showUpdateAvailableSnackBar(String newerVersion) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content:
            Text('Update available: v$newerVersion. Download the APK from the '
                'Releases page and install it manually.'),
        duration: const Duration(seconds: 8),
        action: SnackBarAction(
          label: 'Open Releases',
          onPressed: () => launchUrl(
            Uri.parse(UpdateCheckRepository.releasesPageUrl),
            mode: LaunchMode.externalApplication,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<void>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleSystemBack();
      },
      child: Scaffold(
        extendBody: true,
        body: ListenableBuilder(
          listenable: widget.controller,
          builder: (context, _) => _body(context, widget.controller),
        ),
      ),
    );
  }

  void _handleSystemBack() {
    // Android can deliver both the predictive-back callback and the legacy
    // back event for one gesture. Handle the pair as one user action so the
    // second callback cannot immediately fall through to app exit.
    final handlingNow = DateTime.now();
    final lastHandling = _lastBackHandling;
    if (lastHandling != null &&
        handlingNow.difference(lastHandling) <
            const Duration(milliseconds: 1000)) {
      return;
    }
    _lastBackHandling = handlingNow;
    // Unfocus a focused text field (comment box, Rated Albums search bar,
    // etc.) before anything else — a stray focus left over from typing
    // shouldn't block or confuse the navigation below, and the user
    // expects back to at least drop focus/dismiss the keyboard first.
    final primaryFocus = FocusManager.instance.primaryFocus;
    if (primaryFocus != null &&
        primaryFocus.hasFocus &&
        primaryFocus.context?.widget is EditableText) {
      primaryFocus.unfocus();
      return;
    }
    if (_detailsSheetOpen) {
      Navigator.of(context).maybePop();
      return;
    }
    if (_searchOpen) {
      _closeSearch();
      return;
    }
    final navigator = _menuNavigatorKey.currentState;
    if (navigator?.canPop() ?? false) {
      // Back from a level-2 menu page returns to its level-1 menu page. The
      // card closes only after the nested menu Navigator is back at its root.
      navigator!.pop();
      return;
    }
    // A visible lifted card/menu must always consume back locally. This
    // guard also covers edge-back races where the nested route has just
    // finished popping but the lift animation is still settling.
    if (_liftController.value > 0.01 ||
        _menuOpenState ||
        (_menuNavigatorKey.currentState != null &&
            _menuNavigatorKey.currentState!.mounted &&
            _liftController.status != AnimationStatus.dismissed)) {
      _close();
      return;
    }
    final now = DateTime.now();
    final previous = _lastBackPress;
    if (previous != null &&
        now.difference(previous) <= const Duration(seconds: 2)) {
      SystemNavigator.pop();
      return;
    }
    _lastBackPress = now;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Press back again to exit'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  Widget _body(BuildContext context, DiscoveryController controller) {
    final album = controller.currentAlbum;

    final colors = Theme.of(context).colorScheme;
    final screenHeight = MediaQuery.of(context).size.height;
    final screenWidth = MediaQuery.of(context).size.width;
    // The card is shorter than the screen even at rest, so a sliver of the
    // background color is always visible at the bottom. Fully open leaves a
    // deliberate "lip" of the card visible at the top instead of
    // disappearing entirely — that lip is what a tap or downward swipe acts
    // on to bring it back.
    const restPeek = 12.0;
    // Let the card extend slightly into the status/notification inset so its
    // top edge does not leave an unnecessary gap below the notification shade.
    // The card background must cover the notification/status inset. Its
    // contents remain protected by the SafeArea inside the card.
    const topMargin = 0.0;
    const topRemnant = 96.0;
    final artworkHeight = (screenWidth - 40).clamp(0.0, 480.0);
    // Includes the fixed members slot and SafeArea/action-row spacing so the
    // card never clips its final controls on short displays.
    final contentHeight = artworkHeight + 486.0;
    final availableHeight = screenHeight - topMargin - restPeek;
    final cardHeight =
        contentHeight < availableHeight ? contentHeight : availableHeight;
    final liftAmount = cardHeight - topRemnant;

    return Stack(
      children: [
        // Background — the menu, hidden behind the card until lifted. Its
        // own Navigator, so tapping an entry pushes results in as a
        // horizontal slide via Cupertino's page transition; popping back is
        // handled by `_SwipeBackPop` wrapping each pushed page (Cupertino's
        // own edge-swipe-back gesture is too narrow to rely on — see that
        // class's doc comment).
        Positioned.fill(
          child: Listener(
            onPointerDown: _onDragStart,
            onPointerMove: _onDragUpdate,
            onPointerUp: _onDragEnd,
            child: Container(
              color: colors.surface,
              child: Padding(
                padding: const EdgeInsets.only(top: topRemnant),
                child: AnimatedBuilder(
                  animation: _liftController,
                  builder: (context, child) {
                    // Keep the exposed surface clean while the card is
                    // closed; the menu content fades in with the reveal and
                    // fades back to the solid surface on close.
                    final opacity = Curves.easeOut
                        .transform(_liftController.value.clamp(0.0, 1.0));
                    return IgnorePointer(
                      ignoring: opacity < 0.01,
                      child: Opacity(opacity: opacity, child: child),
                    );
                  },
                  child: Navigator(
                    key: _menuNavigatorKey,
                    onGenerateRoute: (settings) => CupertinoPageRoute(
                      builder: (context) => _MenuHomePage(
                        controller: controller,
                        onAlbumTap: _openRatedAlbum,
                        onClearArtworkCache: _clearArtworkCache,
                        onClearAlbumCache: _clearAlbumCache,
                        onBackup: _backupRatings,
                        onPickBackupFolder: _pickBackupFolder,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),

        // Foreground — the card. Full height at rest (top: 0), so it covers
        // the menu entirely until lifted. Built once and reused via
        // AnimatedBuilder's `child` — only the Positioned wrapper rebuilds
        // every animation tick, not the whole card.
        AnimatedBuilder(
          animation: _liftController,
          child: Listener(
            onPointerDown: _onCardDragStart,
            onPointerMove: _onCardDragUpdate,
            onPointerUp: _onCardDragEnd,
            child: GestureDetector(
              onTap: _close,
              child: Container(
                decoration: BoxDecoration(
                  color: colors.secondaryContainer,
                  borderRadius:
                      const BorderRadius.vertical(bottom: Radius.circular(28)),
                  boxShadow: [
                    BoxShadow(
                        color: colors.shadow.withValues(alpha: 0.25),
                        blurRadius: 16)
                  ],
                ),
                child: SafeArea(
                  child: DefaultTextStyle.merge(
                    style: TextStyle(color: colors.onSecondaryContainer),
                    child: IconTheme(
                      data: IconThemeData(color: colors.onSecondaryContainer),
                      child: AnimatedBuilder(
                        animation: _searchController,
                        builder: (context, _) {
                          final t = _searchController.value;
                          return Stack(
                            children: [
                              Opacity(
                                opacity: 1 - t,
                                child: IgnorePointer(
                                  ignoring: t > 0.01,
                                  child: Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                        20, 8, 20, 12),
                                    child: Listener(
                                      onPointerDown: _onContentDragStart,
                                      onPointerMove: _onContentDragUpdate,
                                      onPointerUp: _onContentDragEnd,
                                      // The card itself closes when its exposed
                                      // lip is tapped. Absorb taps in the card
                                      // content so buttons never bubble into
                                      // that close action.
                                      child: GestureDetector(
                                        onTap: () {},
                                        child: AnimatedSwitcher(
                                          duration: _contentFadeDuration,
                                          // Distinct keys per state — and per album,
                                          // via the mbid — so switching to a new
                                          // recommendation (same widget shape, new
                                          // data) still cross-fades instead of
                                          // popping, same as switching between
                                          // loading/error/empty/album.
                                          child: controller.isLoading
                                              ? KeyedSubtree(
                                                  key:
                                                      const ValueKey('loading'),
                                                  child: _LoadingContent(
                                                      color: colors
                                                          .onSecondaryContainer),
                                                )
                                              : controller.errorMessage != null
                                                  ? KeyedSubtree(
                                                      key: const ValueKey(
                                                          'error'),
                                                      child: _errorContent(
                                                          controller),
                                                    )
                                                  : album == null
                                                      ? const KeyedSubtree(
                                                          key:
                                                              ValueKey('empty'),
                                                          child: Center(
                                                              child: Text(
                                                                  'No recommendation yet.')),
                                                        )
                                                      : KeyedSubtree(
                                                          key: ValueKey(
                                                              'album-${album.mbid}'),
                                                          child: LayoutBuilder(
                                                            builder: (context,
                                                                constraints) {
                                                              return SingleChildScrollView(
                                                                physics:
                                                                    const ClampingScrollPhysics(),
                                                                child:
                                                                    ConstrainedBox(
                                                                  // minHeight (not maxHeight) is what actually lets
                                                                  // Center do its job here: it guarantees this box is
                                                                  // at least as tall as the viewport, so short content
                                                                  // truly centers, while still letting it grow taller
                                                                  // (and the SingleChildScrollView above take over)
                                                                  // when content genuinely overflows. A maxHeight cap
                                                                  // here would do the opposite — shrink-wrap to
                                                                  // content and never give Center any room to work,
                                                                  // which is the bug this replaced.
                                                                  constraints:
                                                                      BoxConstraints(
                                                                    minHeight:
                                                                        constraints
                                                                            .maxHeight,
                                                                  ),
                                                                  child: Center(
                                                                    child:
                                                                        SizedBox(
                                                                      width: constraints.maxWidth >
                                                                              480
                                                                          ? 480
                                                                          : constraints
                                                                              .maxWidth,
                                                                      child: _albumContent(
                                                                          context,
                                                                          controller,
                                                                          album),
                                                                    ),
                                                                  ),
                                                                ),
                                                              );
                                                            },
                                                          ),
                                                        ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              if (_searchOpen || t > 0.01)
                                Opacity(
                                  opacity: t,
                                  child: IgnorePointer(
                                    ignoring: t < 0.99,
                                    child: _searchOverlay(context, controller),
                                  ),
                                ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          builder: (context, child) {
            return Positioned(
              top: topMargin - (_liftController.value * liftAmount),
              left: 0,
              right: 0,
              height: cardHeight,
              child: child!,
            );
          },
        ),
      ],
    );
  }

  Widget _errorContent(DiscoveryController controller) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Something went wrong:\n${controller.errorMessage}',
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.onSecondaryContainer)),
          const SizedBox(height: 16),
          FilledButton(
              onPressed: controller.loadNext, child: const Text('Try again')),
        ],
      ),
    );
  }

  Widget _searchOverlay(BuildContext context, DiscoveryController controller) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchFieldController,
                  focusNode: _searchFocusNode,
                  decoration: const InputDecoration(
                      hintText: 'Search albums…', border: InputBorder.none),
                  textInputAction: TextInputAction.search,
                  onChanged: (query) => _onSearchChanged(controller, query),
                  onSubmitted: (query) => _runSearch(controller, query),
                ),
              ),
              IconButton(
                  icon: const Icon(Icons.close), onPressed: _closeSearch),
            ],
          ),
          const Divider(height: 1),
          Expanded(
            child: Column(
              children: [
                if (_searching) const LinearProgressIndicator(minHeight: 2),
                Expanded(
                  child: _searchResults.isEmpty && _searching
                      ? _LoadingContent(
                          color: Theme.of(context)
                              .colorScheme
                              .onSecondaryContainer)
                      : ListView(
                          children: _searchResults.map((r) {
                            final artist = ((r['artist-credit'] as List?) ?? [])
                                .cast<Map<String, dynamic>>()
                                .map((c) => c['name'] as String)
                                .join(', ');
                            final year = (r['first-release-date'] as String?)
                                    ?.split('-')
                                    .first ??
                                'unknown year';
                            final isRated = controller.ratings
                                    .ratingFor(r['id'] as String) !=
                                null;
                            return ListTile(
                              leading: SizedBox(
                                width: 56,
                                height: 56,
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: _FadingNetworkImage(
                                    url:
                                        CoverArtClient.releaseGroupThumbnailUrl(
                                            r['id'] as String),
                                    placeholder: _artworkPlaceholder(context),
                                  ),
                                ),
                              ),
                              title: Text(
                                  Album.stripOuterBrackets(r['title'] as String)),
                              subtitle: RichText(
                                text: TextSpan(
                                  style: Theme.of(context).textTheme.bodyMedium,
                                  children: [
                                    TextSpan(text: '$artist · $year'),
                                    if (isRated)
                                      TextSpan(
                                        text: ' · Rated',
                                        style: TextStyle(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .primary,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                              onTap: () => _pickSearchResult(
                                  controller, r['id'] as String),
                            );
                          }).toList(),
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _albumContent(
      BuildContext context, DiscoveryController controller, Album album) {
    final detailsFuture = _albumDetailsFutures.putIfAbsent(
      album.mbid,
      () => controller.albums.getDetails(album),
    );
    final existingRating = controller.ratings.ratingFor(album.mbid);
    final currentRatingTier =
        existingRating == null ? null : ratingTierFor(existingRating.stars);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // A fixed 1:1 square regardless of the source image's own
        // proportions — the artwork is always cropped to fit it. Sized to
        // 75% of the available width (Center overrides the Column's
        // stretch just for this child) rather than the full width, so the
        // card's total content is short enough to fit without scrolling on
        // most screens — a shorter Column is what actually lets Center
        // (further up, in the LayoutBuilder wrapper) have real room to
        // vertically center the content, instead of the SingleChildScrollView
        // always taking over because content already fills the viewport.
        Center(
          child: FractionallySizedBox(
            widthFactor: 0.75,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Listener(
                onPointerDown: _onArtworkDragStart,
                onPointerMove: _onArtworkDragUpdate,
                onPointerUp: _onArtworkDragEnd,
                child: GestureDetector(
                  onTap: () => _showPlayOptions(context, controller),
                  child: AnimatedBuilder(
                    animation: _skipController,
                    child: AspectRatio(
                      aspectRatio: 1,
                      child: _FadingNetworkImage(
                        url: album.coverArtUrl ??
                            CoverArtClient.releaseGroupThumbnailUrl(album.mbid,
                                size: 500),
                        placeholder: _artworkPlaceholder(context),
                      ),
                    ),
                    builder: (context, child) {
                      final progress = _skipAlbumMbid == album.mbid
                          ? Curves.easeInCubic.transform(_skipController.value)
                          : 0.0;
                      return Opacity(
                        opacity: 1 - progress,
                        child: FractionalTranslation(
                          translation: Offset(-progress, -0.04 * progress),
                          child: Transform.rotate(
                            angle: -0.08 * progress,
                            child: child,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          album.title,
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              color: Theme.of(context).colorScheme.onSecondaryContainer),
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        Text(
          '${album.artistName} · ${album.firstReleaseYear ?? 'unknown year'}',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSecondaryContainer),
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        SizedBox(
          height: 32,
          child: FutureBuilder<AlbumDetails>(
            future: detailsFuture,
            builder: (context, snapshot) {
              final members = snapshot.data?.members ?? const <String>[];
              if (members.isEmpty) return const SizedBox.expand();
              return AnimatedOpacity(
                opacity:
                    snapshot.connectionState == ConnectionState.done ? 1 : 0,
                duration: const Duration(milliseconds: 300),
                child: Center(
                  child: Text('Members: ${members.join(' · ')}',
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context)
                              .colorScheme
                              .onSecondaryContainer)),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 2),
        TextButton.icon(
          onPressed: () => _showAlbumDetails(context, controller, album,
              detailsFuture: detailsFuture),
          icon: const Icon(Icons.info_outline),
          label: const Text('Details'),
        ),
        const SizedBox(height: 6),
        // Keep the primary controls together so the card has one clear
        // action row. Expanded children keep labels usable on narrow phones.
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: () {
                  if (controller.sessionVibeGenre != null) {
                    controller.clearSessionVibeGenre();
                  } else {
                    _showVibePicker(context, controller);
                  }
                },
                icon: Icon(
                  controller.sessionVibeGenre == null
                      ? Icons.auto_awesome
                      : Icons.lock,
                  size: 18,
                ),
                label: Text(
                  controller.sessionVibeGenre == null
                      ? 'Vibe'
                      : controller.sessionVibeGenre!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: FilledButton.icon(
                onPressed: () => _showPlayOptions(context, controller),
                icon: const Icon(Icons.play_arrow),
                label: const Text('Play'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _OwnershipButton(
                icon: Icons.album,
                label: 'CD',
                selected: album.ownsCd,
                onPressed: controller.toggleOwnsCd,
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: _OwnershipButton(
                icon: Icons.album_outlined,
                label: 'Vinyl',
                selected: album.ownsVinyl,
                onPressed: controller.toggleOwnsVinyl,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _RatingButtons(
          // Keyed by album so a fresh selection state starts each time a
          // new album arrives, instead of carrying over the previous
          // album's in-progress (not-yet-submitted) selection.
          key: ValueKey(album.mbid),
          currentTier: currentRatingTier,
          onRate: (tier) => controller.rate(tier.value),
        ),
        // Deliberately low-emphasis — a "not right now" escape, not a
        // competing call to action next to Rate/Play. Not a dislike: no
        // rating is recorded, and it doesn't touch the anchor or pivot.
        Center(
          child: TextButton(
            onPressed: () => _animateAlbumSkip(fromButton: true),
            style: TextButton.styleFrom(
              foregroundColor:
                  Theme.of(context).colorScheme.onSecondaryContainer,
              visualDensity: VisualDensity.compact,
            ),
            child: Text(
              'Not for me right now',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSecondaryContainer),
            ),
          ),
        ),
      ],
    );
  }

  Widget _artworkPlaceholder(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      // Match the exposed background card so a missing-art cover has a
      // visible contrast during the left-swipe exit animation.
      color: colors.surface,
      child: Icon(Icons.album, size: 64, color: colors.onSurfaceVariant),
    );
  }

  Future<void> _showAlbumDetails(
      BuildContext context, DiscoveryController controller, Album album,
      {Future<AlbumDetails>? detailsFuture}) async {
    // Tracked so _handleSystemBack knows to close this sheet on back — the
    // global navigation-channel override below (see initState) means the
    // framework's normal Navigator.maybePop()/PopScope handling for this
    // modal route never runs; without this flag, back had no branch that
    // closed the sheet at all and could fall through to double-back-exit.
    _detailsSheetOpen = true;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => AlbumDetailsSheet(
        album: album,
        detailsFuture: detailsFuture ?? controller.albums.getDetails(album),
        notes: controller.notes,
      ),
    );
    _detailsSheetOpen = false;
  }

  Future<void> _showVibePicker(
      BuildContext context, DiscoveryController controller) async {
    final genre = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: genrePool.length,
          itemBuilder: (context, index) {
            final genre = genrePool[index];
            return ListTile(
              leading: const Icon(Icons.music_note),
              title: Text(genre),
              onTap: () => Navigator.pop(context, genre),
            );
          },
        ),
      ),
    );
    if (!mounted || genre == null) return;
    controller.setSessionVibeGenre(genre);
  }

  void _showPlayOptions(BuildContext context, DiscoveryController controller) {
    // A default player app is configured — fire straight into it (direct
    // link if this album has one, else a search scoped to that same
    // service) and skip the picker entirely. No default set at all keeps
    // today's full-picker behavior completely unchanged, below.
    final defaultPlayerApp = controller.settings.defaultPlayerApp();
    if (defaultPlayerApp != null) {
      final url = controller.directLinkFor(defaultPlayerApp) ??
          controller.searchUrlFor(defaultPlayerApp);
      if (url != null) {
        launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
        return;
      }
    }

    final links = controller.playLinks;
    final entries = links.isEmpty
        ? {'Search (no direct link found)': controller.fallbackSearchUrl()}
            .entries
        : links.entries;

    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: entries
              .map((entry) => ListTile(
                    title: Text(entry.key),
                    onTap: () {
                      Navigator.pop(context);
                      launchUrl(Uri.parse(entry.value),
                          mode: LaunchMode.externalApplication);
                    },
                  ))
              .toList(),
        ),
      ),
    );
  }
}

/// Three-button rating input (dislike/like/love) — replaces the old 1-5
/// slider (see architecture.md). Tapping a tier button only *selects* it
/// (animated, so the tap has visible feedback) — it does not submit, since
/// [onRate] triggers `DiscoveryController.rate()`, which immediately fetches
/// and displays the next album. Selecting first, then pressing the "Rate"
/// button below, leaves time to toggle CD/vinyl or write a comment (via
/// Details) before moving on. Stateful (not the previous StatelessWidget)
/// so a selection can exist before being submitted; the parent keys this
/// widget by album mbid so that in-progress selection doesn't leak across
/// albums when a new one arrives unsubmitted.
class _RatingButtons extends StatefulWidget {
  final RatingTier? currentTier;
  final void Function(RatingTier tier) onRate;

  const _RatingButtons(
      {super.key, required this.currentTier, required this.onRate});

  @override
  State<_RatingButtons> createState() => _RatingButtonsState();
}

class _RatingButtonsState extends State<_RatingButtons> {
  late RatingTier? _selected = widget.currentTier;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      children: [
        Row(
          children: [
            Expanded(
                child:
                    _tierButton(colors, RatingTier.dislike, Icons.thumb_down)),
            Expanded(
                child: _tierButton(colors, RatingTier.like, Icons.thumb_up)),
            Expanded(child: _tierButton(colors, RatingTier.love, Icons.bolt)),
          ],
        ),
        const SizedBox(height: 4),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: colors.tertiary,
              foregroundColor: colors.onTertiary,
            ),
            onPressed:
                _selected == null ? null : () => widget.onRate(_selected!),
            // An album that already had a rating when this sheet opened
            // isn't being rated for the first time — pressing this button
            // mostly just means "move on", so it reads as "Next" rather
            // than "Rate". Still submits whatever tier is selected either
            // way (harmless re-submit of the same rating if unchanged).
            child: Text(widget.currentTier == null ? 'Rate' : 'Next'),
          ),
        ),
      ],
    );
  }

  // Padding reserves headroom *inside* each Expanded slot, so the scale-up
  // below grows into that padding rather than past the slot's own boundary
  // — otherwise the animation visibly clips against its neighbor/the row's
  // edge, since Transform.scale (which AnimatedScale uses) doesn't reserve
  // any extra layout space of its own.
  Widget _tierButton(ColorScheme colors, RatingTier tier, IconData icon) {
    final selected = tier == _selected;
    return Padding(
      padding: const EdgeInsets.all(4),
      child: AnimatedScale(
        scale: selected ? 1.06 : 1.0,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
        child: selected
            ? FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: colors.tertiary,
                  foregroundColor: colors.onTertiary,
                ),
                onPressed: () => setState(() => _selected = tier),
                child: Icon(icon),
              )
            : FilledButton.tonal(
                style: FilledButton.styleFrom(
                  backgroundColor: colors.tertiaryContainer,
                  foregroundColor: colors.onTertiaryContainer,
                ),
                onPressed: () => setState(() => _selected = tier),
                child: Icon(icon),
              ),
      ),
    );
  }
}

/// A pill-shaped ownership toggle (CD/vinyl) — plain filled/tonal buttons,
/// no checkbox, matching the rating buttons' shape. Secondary-colored, to
/// visually group with the rating row's tertiary and the primary-colored
/// Vibe/Play row above — three rows, three distinct palette roles.
class _OwnershipButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onPressed;

  const _OwnershipButton({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(4),
      child: AnimatedScale(
        scale: selected ? 1.04 : 1.0,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
        child: selected
            ? FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: colors.secondary,
                  foregroundColor: colors.onSecondary,
                ),
                onPressed: onPressed,
                icon: Icon(icon, size: 18),
                label: Text(label),
              )
            : FilledButton.tonalIcon(
                style: FilledButton.styleFrom(
                  backgroundColor: colors.secondaryContainer,
                  foregroundColor: colors.onSecondaryContainer,
                ),
                onPressed: onPressed,
                icon: Icon(icon, size: 18),
                label: Text(label),
              ),
      ),
    );
  }
}

/// The background menu's home page — just the entry list, anchored to the
/// bottom (the edge revealed first as the card lifts).
class _MenuHomePage extends StatelessWidget {
  final DiscoveryController controller;
  final Future<void> Function(String mbid) onAlbumTap;
  final Future<void> Function() onClearArtworkCache;
  final VoidCallback onClearAlbumCache;
  final Future<void> Function() onBackup;
  final Future<String?> Function() onPickBackupFolder;

  const _MenuHomePage(
      {required this.controller,
      required this.onAlbumTap,
      required this.onClearArtworkCache,
      required this.onClearAlbumCache,
      required this.onBackup,
      required this.onPickBackupFolder});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _MenuAction(
                icon: Icons.tune,
                label: 'Liked genres',
                onTap: () => Navigator.of(context).push(
                  CupertinoPageRoute(
                    builder: (context) => _SwipeBackPop(
                      child: _GenrePickerPage(controller: controller),
                    ),
                  ),
                ),
              ),
              _MenuAction(
                icon: Icons.history,
                label: 'Rated albums',
                onTap: () => Navigator.of(context).push(
                  CupertinoPageRoute(
                    builder: (context) => _SwipeBackPop(
                      child: RatedAlbumsPage(
                        ratingRepository: controller.ratings,
                        albumRepository: controller.albums,
                        savedFilterRepository: controller.savedFilters,
                        settings: controller.settings,
                        notes: controller.notes,
                        onAlbumTap: onAlbumTap,
                      ),
                    ),
                  ),
                ),
              ),
              _MenuAction(
                icon: Icons.settings,
                label: 'Settings',
                onTap: () => Navigator.of(context).push(
                  CupertinoPageRoute(
                    builder: (context) => _SwipeBackPop(
                        child: SettingsPage(
                            settings: controller.settings,
                            onResetSkipPenalties: controller.resetSkipPenalties,
                            onClearArtworkCache: onClearArtworkCache,
                            onClearAlbumCache: onClearAlbumCache,
                            onBackup: onBackup,
                            onPickBackupFolder: onPickBackupFolder,
                            onCheckForUpdate: () =>
                                controller.checkForUpdate(force: true),
                            onRefreshRatedAlbumsMetadata:
                                controller.refreshRatedAlbumsMetadata)),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              GestureDetector(
                onTap: () => _checkForUpdate(context),
                child: Text(
                  'v$appVersion · alpha',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _checkForUpdate(BuildContext context) async {
    final (succeeded, newerVersion) =
        await controller.checkForUpdate(force: true);
    if (!context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    if (!succeeded) {
      messenger.showSnackBar(const SnackBar(
          content: Text("Couldn't check for updates. Try again later.")));
    } else if (newerVersion != null) {
      messenger.showSnackBar(SnackBar(
        content:
            Text('Update available: v$newerVersion. Download the APK from the '
                'Releases page and install it manually.'),
        duration: const Duration(seconds: 8),
        action: SnackBarAction(
          label: 'Open Releases',
          onPressed: () => launchUrl(
            Uri.parse(UpdateCheckRepository.releasesPageUrl),
            mode: LaunchMode.externalApplication,
          ),
        ),
      ));
    } else {
      messenger.showSnackBar(
          const SnackBar(content: Text("You're on the latest version.")));
    }
  }
}

/// Wraps a pushed sub-page with a full-screen swipe-right-to-pop gesture.
/// Cupertino's own back gesture only answers to drags starting within the
/// leftmost 20 logical pixels — too narrow to feel reliable, and the user
/// wants this to work from anywhere on the page. A `Listener` (not
/// `GestureDetector`) tracks raw pointer movement regardless of what any
/// descendant Scrollable does with the same pointer — e.g. RatedAlbumsPage's
/// horizontally-scrolling filter-chip row keeps scrolling normally, this
/// still tracks the horizontal drag in parallel instead of losing the
/// gesture-arena fight to it.
class _SwipeBackPop extends StatefulWidget {
  final Widget child;

  const _SwipeBackPop({required this.child});

  @override
  State<_SwipeBackPop> createState() => _SwipeBackPopState();
}

class _SwipeBackPopState extends State<_SwipeBackPop> {
  double _dragAccum = 0;
  double _startX = 0;
  bool _useCustomSwipe = false;

  static const _triggerDistance = 60.0;

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (event) {
        _dragAccum = 0;
        _startX = event.position.dx;
        // CupertinoPageRoute already owns the edge gesture. Avoid running
        // the raw fallback at the same time, which can pop the route twice
        // and briefly expose the previous page during the reverse animation.
        _useCustomSwipe = _startX > 24;
      },
      onPointerMove: (event) {
        if (_useCustomSwipe) _dragAccum += event.delta.dx;
      },
      onPointerUp: (_) {
        if (_useCustomSwipe && _dragAccum > _triggerDistance) {
          Navigator.of(context).maybePop();
        }
        _useCustomSwipe = false;
      },
      onPointerCancel: (_) => _useCustomSwipe = false,
      child: widget.child,
    );
  }
}

/// Pushed on top of the menu home page — slides in horizontally, and
/// swiping right anywhere on the page (via `_SwipeBackPop`, wrapped at the
/// push call site in `_MenuHomePage`) pops back to the menu.
class _GenrePickerPage extends StatefulWidget {
  final DiscoveryController controller;
  final bool onboarding;
  final Future<void> Function()? onDone;

  const _GenrePickerPage(
      {required this.controller, this.onboarding = false, this.onDone});

  @override
  State<_GenrePickerPage> createState() => _GenrePickerPageState();
}

class _GenrePickerPageState extends State<_GenrePickerPage> {
  late final Set<String> _selected = widget.controller.likedGenres().toSet();

  // Applies immediately — there's no separate Save step. Leaving the page
  // (back button, or the standard right-swipe) just keeps whatever's
  // currently selected.
  void _toggle(String genre, bool isSelected) {
    setState(() => isSelected ? _selected.add(genre) : _selected.remove(genre));
    widget.controller.setLikedGenres(_selected.toList());
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !widget.onboarding,
      child: Material(
        color: Theme.of(context).colorScheme.surface,
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 8, 16, 0),
                child: SizedBox(
                  height: 40,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Text('Liked genres',
                          style: Theme.of(context).textTheme.titleLarge),
                      if (widget.onboarding)
                        Align(
                          alignment: Alignment.centerRight,
                          child: FilledButton(
                            onPressed: _selected.isEmpty ? null : widget.onDone,
                            child: const Text('Done'),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: genrePool.map((genre) {
                      return FilterChip(
                        label: Text(genre),
                        selected: _selected.contains(genre),
                        onSelected: (isSelected) => _toggle(genre, isSelected),
                      );
                    }).toList(),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A row in the background menu — icon and label.
class _MenuAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _MenuAction(
      {required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          children: [
            Icon(icon),
            const SizedBox(width: 12),
            Text(label, style: Theme.of(context).textTheme.titleMedium),
          ],
        ),
      ),
    );
  }
}

/// A simple three-dot staggered bounce, shown in place of the album content
/// while a recommendation is loading — the card itself never disappears.
class _LoadingContent extends StatefulWidget {
  final Color color;

  const _LoadingContent({required this.color});

  @override
  State<_LoadingContent> createState() => _LoadingContentState();
}

class _LoadingContentState extends State<_LoadingContent>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 900))
    ..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(3, (i) {
          return AnimatedBuilder(
            animation: _controller,
            builder: (context, _) {
              final t = (_controller.value - (i * 0.2)) % 1.0;
              final bounce = t < 0.5
                  ? Curves.easeOut.transform(t * 2)
                  : Curves.easeIn.transform(1 - (t - 0.5) * 2);
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Transform.translate(
                  offset: Offset(0, -bounce * 8),
                  child: Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                        color: widget.color, shape: BoxShape.circle),
                  ),
                ),
              );
            },
          );
        }),
      ),
    );
  }
}

/// Cover art over a network connection: the placeholder sits underneath the
/// whole time, so there's always something visible immediately, and the
/// image itself fades in on top of it once its first frame has decoded
/// (`frameBuilder`'s `frame` goes from null to non-null). Cached/already
/// -decoded images (`wasSynchronouslyLoaded`) skip the fade entirely — that
/// case has no loading latency to smooth over, and fading it anyway would
/// just be a needless flicker.
class _FadingNetworkImage extends StatelessWidget {
  final String url;
  final Widget placeholder;

  static const _fadeDuration = Duration(milliseconds: 300);

  const _FadingNetworkImage({required this.url, required this.placeholder});

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        placeholder,
        CachedNetworkImage(
          imageUrl: url,
          cacheManager: ArtworkCache.manager,
          fit: BoxFit.cover,
          placeholder: (context, url) => placeholder,
          errorWidget: (context, url, error) => placeholder,
          useOldImageOnUrlChange: true,
          fadeInDuration: _fadeDuration,
        ),
      ],
    );
  }
}
