import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'config/theme.dart';
import 'models/interaction_models.dart';
import 'services/app_update_service.dart';
import 'services/app_telemetry_service.dart';
import 'services/download_manager_service.dart';
import 'services/growth_service.dart';
import 'services/interaction_service.dart';
import 'services/progress_sync_service.dart';
import 'services/storage_service.dart';
import 'services/tts_media_control_service.dart';
import 'providers/bookshelf_provider.dart';
import 'providers/book_source_provider.dart';
import 'providers/interaction_auth_provider.dart';
import 'providers/reading_provider.dart';
import 'providers/tts_provider.dart';
import 'screens/anime_screen.dart';
import 'screens/manga_screen.dart';
import 'screens/search_screen.dart';
import 'screens/profile_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final ttsMediaControlFuture = _initTtsMediaControlSafely();
  final storageInitWatch = Stopwatch()..start();
  final storageService = StorageService();
  try {
    await storageService.init();
  } catch (error, stackTrace) {
    debugPrint('App storage initialization failed: $error\n$stackTrace');
    runApp(_StartupFailureApp(error: error));
    return;
  }
  storageInitWatch.stop();
  final telemetry = AppTelemetryService.instance;
  unawaited(
    telemetry.init().then((_) {
      telemetry.trackEvent(
        'storage_init',
        durationMs: storageInitWatch.elapsedMilliseconds,
        metadata: {
          'legacyMigrationRan': storageService.didMigrateLegacyProgress,
        },
      );
    }),
  );
  unawaited(DownloadManagerService.instance.init());
  final previousFlutterErrorHandler = FlutterError.onError;
  FlutterError.onError = (details) {
    telemetry.captureFlutterError(details);
    if (previousFlutterErrorHandler != null) {
      previousFlutterErrorHandler(details);
    } else {
      FlutterError.presentError(details);
    }
  };
  final previousPlatformErrorHandler = PlatformDispatcher.instance.onError;
  PlatformDispatcher.instance.onError = (error, stack) {
    telemetry.captureError(error, stack, fatal: true);
    return previousPlatformErrorHandler?.call(error, stack) ?? false;
  };
  final ttsMediaControlService = await ttsMediaControlFuture;

  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
    ),
  );

  runApp(NovelApp(ttsMediaControlService: ttsMediaControlService));
}

Future<TtsMediaControlService> _initTtsMediaControlSafely() async {
  try {
    return await TtsMediaControlService.init().timeout(
      const Duration(seconds: 8),
    );
  } catch (error, stackTrace) {
    debugPrint('TTS media controls are unavailable: $error\n$stackTrace');
    return TtsMediaControlService.disabled();
  }
}

class _StartupFailureApp extends StatelessWidget {
  const _StartupFailureApp({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      home: Scaffold(
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.error_outline, size: 54),
                    const SizedBox(height: 16),
                    Text(
                      '应用初始化失败',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      '请完全退出应用后重新打开。如果仍然出现，请把此页面截图发给管理员。',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      error.toString(),
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class NovelApp extends StatefulWidget {
  const NovelApp({super.key, this.ttsMediaControlService});

  final TtsMediaControlService? ttsMediaControlService;

  @override
  State<NovelApp> createState() => _NovelAppState();
}

class _NovelAppState extends State<NovelApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    AppTelemetryService.instance.handleLifecycle(state);
    ProgressSyncService.instance.handleLifecycle(state);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(AppTelemetryService.instance.flush());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => BookshelfProvider()),
        ChangeNotifierProvider(
          create: (_) => InteractionAuthProvider()..loadSession(),
        ),
        ChangeNotifierProvider(create: (_) => BookSourceProvider()),
        ChangeNotifierProvider(
          create: (_) => ReadingProvider()..loadSettings(),
        ),
        ChangeNotifierProvider(
          create: (_) =>
              TtsProvider(mediaControlService: widget.ttsMediaControlService),
        ),
      ],
      child: Consumer<ReadingProvider>(
        builder: (context, readingProvider, _) => MaterialApp(
          title: 'Sakura',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.lightTheme,
          darkTheme: AppTheme.darkTheme,
          themeMode: readingProvider.settings.nightMode
              ? ThemeMode.dark
              : ThemeMode.light,
          home: const MainScaffold(),
        ),
      ),
    );
  }
}

class MainScaffold extends StatefulWidget {
  const MainScaffold({super.key});

  @override
  State<MainScaffold> createState() => _MainScaffoldState();
}

class _MainScaffoldState extends State<MainScaffold> {
  final AppUpdateService _startupUpdateService = AppUpdateService();
  final InteractionService _interactionService = InteractionService();
  static const String _announcementSeenKey = 'app_announcement_seen_id';
  int _currentIndex = 0;
  final Set<int> _visitedTabIndexes = {0};
  late final List<_TabRouteObserver> _routeObservers;
  final List<bool> _hideBottomNavByTab = List<bool>.filled(4, false);
  late final List<GlobalKey<NavigatorState>> _navigatorKeys = List.generate(
    4,
    (_) => GlobalKey<NavigatorState>(),
  );
  late final List<HeroController> _heroControllers = List.generate(
    4,
    (_) => MaterialApp.createMaterialHeroController(),
  );
  bool _didCheckStartupUpdate = false;
  bool _didCheckStartupAnnouncement = false;
  static const List<String> _tabTelemetryNames = [
    'novel_home',
    'manga_home',
    'anime_home',
    'profile_home',
  ];

  @override
  void initState() {
    super.initState();
    _routeObservers = List.generate(
      4,
      (index) => _TabRouteObserver(
        onChanged: (hideBottomNav) {
          if (!mounted || _hideBottomNavByTab[index] == hideBottomNav) return;
          setState(() => _hideBottomNavByTab[index] = hideBottomNav);
        },
      ),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      AppTelemetryService.instance.trackEvent(
        'tab_view',
        screen: _tabTelemetryNames[_currentIndex],
        metadata: const {'initial': true},
      );
      unawaited(_runStartupChecks());
    });
  }

  Future<void> _runStartupChecks() async {
    final bootstrapFuture = _loadAppBootstrap();
    await _checkStartupUpdate();
    await _checkStartupAnnouncement();
    await bootstrapFuture;
  }

  Future<void> _loadAppBootstrap() async {
    try {
      final token = context.read<InteractionAuthProvider>().token;
      await GrowthService.instance.fetchBootstrap(token: token);
    } catch (_) {
      // Bootstrap controls are best-effort; cached/default behavior remains.
    }
  }

  void _selectTab(int index) {
    if (index == _currentIndex) return;
    setState(() {
      _visitedTabIndexes.add(index);
      _currentIndex = index;
    });
    AppTelemetryService.instance.trackEvent(
      'tab_view',
      screen: _tabTelemetryNames[index],
      metadata: {'index': index},
    );
  }

  Future<void> _handleBackNavigation() async {
    final navigator = _navigatorKeys[_currentIndex].currentState;
    await navigator?.maybePop();
  }

  Future<void> _checkStartupUpdate() async {
    if (_didCheckStartupUpdate) return;
    _didCheckStartupUpdate = true;

    AppUpdateCheckResult result;
    try {
      result = await _startupUpdateService.checkForUpdate();
    } catch (_) {
      return;
    }
    if (!mounted || !result.hasUpdate || result.update == null) return;

    final update = result.update!;
    final confirmed = await _confirmStartupUpdate(update);
    if (confirmed == true && mounted) {
      await _downloadAndInstallStartupUpdate(update);
    }
  }

  Future<void> _checkStartupAnnouncement() async {
    if (_didCheckStartupAnnouncement) return;
    _didCheckStartupAnnouncement = true;
    AppAnnouncement announcement;
    try {
      announcement = await _interactionService.fetchAppAnnouncement();
    } catch (_) {
      return;
    }
    if (!mounted || !announcement.shouldShow) return;
    final storage = StorageService();
    if (storage.getString(_announcementSeenKey) == announcement.id) return;
    await _showStartupAnnouncement(announcement);
    if (!mounted) return;
    await storage.setString(_announcementSeenKey, announcement.id);
  }

  Future<void> _showStartupAnnouncement(AppAnnouncement announcement) {
    return showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) => AlertDialog(
        title: Text(announcement.title.isEmpty ? '公告' : announcement.title),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: SingleChildScrollView(child: Text(announcement.content)),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  Future<bool?> _confirmStartupUpdate(AppUpdateInfo update) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: !update.force,
      builder: (dialogContext) => PopScope(
        canPop: !update.force,
        child: AlertDialog(
          title: Text('发现新版本 ${update.versionName}'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('版本号：${update.versionCode}'),
                  if (update.notes.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    for (final note in update.notes)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text('• $note'),
                      ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            if (!update.force)
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('稍后'),
              ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('立即更新'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _downloadAndInstallStartupUpdate(AppUpdateInfo update) async {
    final progress = ValueNotifier<double?>(null);
    var dialogOpen = false;
    var closeRequested = false;
    BuildContext? progressDialogContext;
    var wakelockWasEnabled = false;
    var wakelockChanged = false;

    void closeProgressDialog() {
      closeRequested = true;
      if (!dialogOpen || !mounted || progressDialogContext == null) return;
      dialogOpen = false;
      Navigator.of(progressDialogContext!, rootNavigator: true).pop();
    }

    dialogOpen = true;
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) {
          progressDialogContext = dialogContext;
          if (closeRequested) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (Navigator.canPop(dialogContext)) {
                Navigator.of(dialogContext, rootNavigator: true).pop();
              }
            });
          }
          return PopScope(
            canPop: false,
            child: AlertDialog(
              title: const Text('正在下载更新'),
              content: ValueListenableBuilder<double?>(
                valueListenable: progress,
                builder: (context, value, _) {
                  final hasProgress = value != null && value > 0;
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      LinearProgressIndicator(
                        value: hasProgress ? value : null,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        hasProgress
                            ? '${(value.clamp(0, 1) * 100).toStringAsFixed(0)}%'
                            : '准备下载...',
                      ),
                    ],
                  );
                },
              ),
            ),
          );
        },
      ).whenComplete(() {
        dialogOpen = false;
      }),
    );

    try {
      try {
        wakelockWasEnabled = await WakelockPlus.enabled;
        await WakelockPlus.enable();
        wakelockChanged = !wakelockWasEnabled;
      } catch (_) {
        // Updating can continue even if the device refuses wakelock changes.
      }

      final apk = await _startupUpdateService.downloadApk(
        update,
        onProgress: (received, total) {
          if (total <= 0) return;
          progress.value = received / total;
        },
      );
      progress.value = 1;
      closeProgressDialog();
      await _startupUpdateService.installApk(apk);
    } catch (error) {
      closeProgressDialog();
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text('更新失败：${_friendlyStartupUpdateError(error)}'),
            ),
          );
      }
    } finally {
      progress.dispose();
      if (wakelockChanged) {
        try {
          await WakelockPlus.disable();
        } catch (_) {
          // Ignore cleanup failures.
        }
      }
    }
  }

  String _friendlyStartupUpdateError(Object error) {
    final text = error.toString().replaceFirst('Exception: ', '');
    if (text.contains('checksum')) return '安装包校验失败';
    if (text.contains('APK download failed')) return '安装包下载失败';
    if (text.contains('install')) return '无法调起安装程序';
    return text.isEmpty ? '请稍后重试' : text;
  }

  Widget _buildTabNavigator(int index) {
    return HeroControllerScope(
      controller: _heroControllers[index],
      child: Navigator(
        key: _navigatorKeys[index],
        observers: [_routeObservers[index]],
        onGenerateRoute: (settings) {
          return MaterialPageRoute<void>(
            settings: settings,
            builder: (_) => _buildRootPage(index),
          );
        },
      ),
    );
  }

  Widget _buildRootPage(int index) {
    switch (index) {
      case 0:
        return const SearchScreen(autofocus: false);
      case 1:
        return const MangaScreen();
      case 2:
        return const AnimeScreen();
      case 3:
        return const ProfileScreen();
      default:
        return const SearchScreen(autofocus: false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final useNavigationRail = MediaQuery.sizeOf(context).width >= 720;
    final hideNav = _hideBottomNavByTab[_currentIndex];
    final pages = IndexedStack(
      index: _currentIndex,
      children: List.generate(
        4,
        (index) => _visitedTabIndexes.contains(index)
            ? _buildTabNavigator(index)
            : const SizedBox.shrink(),
      ),
    );
    return PopScope<void>(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        unawaited(_handleBackNavigation());
      },
      child: Scaffold(
        body: useNavigationRail && !hideNav
            ? Row(
                children: [
                  SafeArea(
                    child: NavigationRail(
                      selectedIndex: _currentIndex,
                      onDestinationSelected: _selectTab,
                      labelType: NavigationRailLabelType.all,
                      minWidth: 76,
                      destinations: const [
                        NavigationRailDestination(
                          icon: Icon(Icons.menu_book_outlined),
                          label: Text('小说'),
                        ),
                        NavigationRailDestination(
                          icon: Icon(Icons.auto_stories_outlined),
                          label: Text('漫画'),
                        ),
                        NavigationRailDestination(
                          icon: Icon(Icons.movie_filter_outlined),
                          label: Text('动漫'),
                        ),
                        NavigationRailDestination(
                          icon: Icon(Icons.person_outline),
                          label: Text('我的'),
                        ),
                      ],
                    ),
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(child: pages),
                ],
              )
            : pages,
        bottomNavigationBar: hideNav || useNavigationRail
            ? null
            : BottomNavigationBar(
                currentIndex: _currentIndex,
                onTap: _selectTab,
                items: const [
                  BottomNavigationBarItem(
                    icon: Icon(Icons.menu_book_outlined),
                    label: '小说',
                  ),
                  BottomNavigationBarItem(
                    icon: Icon(Icons.auto_stories_outlined),
                    label: '漫画',
                  ),
                  BottomNavigationBarItem(
                    icon: Icon(Icons.movie_filter_outlined),
                    label: '动漫',
                  ),
                  BottomNavigationBarItem(
                    icon: Icon(Icons.person_outline),
                    label: '我的',
                  ),
                ],
              ),
      ),
    );
  }
}

class _TabRouteObserver extends NavigatorObserver {
  _TabRouteObserver({required this.onChanged});

  final ValueChanged<bool> onChanged;
  final List<Route<dynamic>> _routes = [];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.add(route);
    _emit();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    _emit();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    _emit();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (oldRoute != null) {
      final index = _routes.indexOf(oldRoute);
      if (index >= 0) {
        if (newRoute != null) {
          _routes[index] = newRoute;
        } else {
          _routes.removeAt(index);
        }
      }
    } else if (newRoute != null) {
      _routes.add(newRoute);
    }
    _emit();
  }

  void _emit() {
    final pageRouteCount = _routes.whereType<PageRoute<dynamic>>().length;
    onChanged(pageRouteCount > 1);
  }

  void reset() {
    _routes.clear();
    _emit();
  }
}
