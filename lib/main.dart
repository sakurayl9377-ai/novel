import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'config/theme.dart';
import 'models/interaction_models.dart';
import 'models/login_reward_notice.dart';
import 'services/app_update_service.dart';
import 'services/app_telemetry_service.dart';
import 'services/download_manager_service.dart';
import 'services/growth_service.dart';
import 'services/interaction_service.dart';
import 'services/login_reward_service.dart';
import 'services/modao_game_service.dart';
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
import 'screens/modao_payment_screen.dart';
import 'screens/modao_sso_authorization_screen.dart';
import 'screens/search_screen.dart';
import 'screens/profile_screen.dart';
import 'screens/reading_screen.dart';
import 'screens/video_screen.dart';
import 'widgets/tts_mini_player.dart';

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
  late final InteractionAuthProvider _interactionAuthProvider;
  late final ReadingProvider _readingProvider;

  @override
  void initState() {
    super.initState();
    _interactionAuthProvider = InteractionAuthProvider();
    _readingProvider = ReadingProvider();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_loadSessionSafely());
    unawaited(_loadReadingSettingsSafely());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    AppTelemetryService.instance.handleLifecycle(state);
    ProgressSyncService.instance.handleLifecycle(state);
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      unawaited(_flushReadingSettingsSafely());
    }
  }

  Future<void> _loadSessionSafely() async {
    try {
      await _interactionAuthProvider.loadSession();
    } catch (error, stackTrace) {
      debugPrint('Session restoration failed: $error\n$stackTrace');
    }
  }

  Future<void> _loadReadingSettingsSafely() async {
    try {
      await _readingProvider.loadSettings();
    } catch (error, stackTrace) {
      debugPrint('Reader settings restoration failed: $error\n$stackTrace');
    }
  }

  Future<void> _flushReadingSettingsSafely() async {
    try {
      await _readingProvider.flushPendingSettings();
    } catch (error, stackTrace) {
      debugPrint('Reader settings persistence failed: $error\n$stackTrace');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _readingProvider.dispose();
    _interactionAuthProvider.dispose();
    unawaited(AppTelemetryService.instance.flush());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => BookshelfProvider()),
        ChangeNotifierProvider<InteractionAuthProvider>.value(
          value: _interactionAuthProvider,
        ),
        ChangeNotifierProvider(create: (_) => BookSourceProvider()),
        ChangeNotifierProvider<ReadingProvider>.value(value: _readingProvider),
        ChangeNotifierProxyProvider<InteractionAuthProvider, TtsProvider>(
          create: (_) =>
              TtsProvider(mediaControlService: widget.ttsMediaControlService),
          update: (_, auth, tts) {
            final provider =
                tts ??
                TtsProvider(mediaControlService: widget.ttsMediaControlService);
            provider.updateAuthToken(auth.token);
            return provider;
          },
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

class _MainScaffoldState extends State<MainScaffold>
    with WidgetsBindingObserver {
  final AppUpdateService _startupUpdateService = AppUpdateService();
  final InteractionService _interactionService = InteractionService();
  final LoginRewardService _loginRewardService = LoginRewardService();
  final ModaoPaymentBridge _modaoPaymentBridge = ModaoPaymentBridge();
  static const String _announcementSeenKey = 'app_announcement_seen_id';
  int _currentIndex = 0;
  final Set<int> _visitedTabIndexes = {0};
  late final List<_TabRouteObserver> _routeObservers;
  final List<bool> _hideBottomNavByTab = List<bool>.filled(5, false);
  final List<Route<dynamic>?> _topRoutesByTab = List<Route<dynamic>?>.filled(
    5,
    null,
  );
  final List<int> _topRouteVersionsByTab = List<int>.filled(5, 0);
  late final List<GlobalKey<NavigatorState>> _navigatorKeys = List.generate(
    5,
    (_) => GlobalKey<NavigatorState>(),
  );
  late final List<HeroController> _heroControllers = List.generate(
    5,
    (_) => MaterialApp.createMaterialHeroController(),
  );
  bool _didCheckStartupUpdate = false;
  bool _didCheckStartupAnnouncement = false;
  bool _startupChecksCompleted = false;
  bool _externalRequestDrainRunning = false;
  bool _externalRequestDrainRequested = false;
  InteractionAuthProvider? _authProvider;
  String _lastLoginRewardToken = '';
  bool _loginRewardSyncRunning = false;
  bool _loginRewardResyncRequested = false;
  static const List<String> _tabTelemetryNames = [
    'novel_home',
    'manga_home',
    'anime_home',
    'video_home',
    'profile_home',
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _modaoPaymentBridge.start(
      onPaymentRequestAvailable: _scheduleExternalRequestDrain,
      onSsoAuthorizationRequestAvailable: _scheduleExternalRequestDrain,
    );
    _routeObservers = List.generate(
      5,
      (index) => _TabRouteObserver(
        onChanged: (hideBottomNav) {
          if (!mounted || _hideBottomNavByTab[index] == hideBottomNav) return;
          setState(() => _hideBottomNavByTab[index] = hideBottomNav);
        },
        onTopRouteChanged: (route) {
          if (identical(_topRoutesByTab[index], route)) return;
          final version = ++_topRouteVersionsByTab[index];
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || version != _topRouteVersionsByTab[index]) return;
            if (identical(_topRoutesByTab[index], route)) return;
            setState(() => _topRoutesByTab[index] = route);
          });
        },
      ),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      AppTelemetryService.instance.trackEvent(
        'tab_view',
        screen: _tabTelemetryNames[_currentIndex],
        metadata: const {'initial': true},
      );
      unawaited(_runInitialExternalFlowAndStartupChecks());
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = context.read<InteractionAuthProvider>();
    if (!identical(_authProvider, next)) {
      _authProvider?.removeListener(_handleAuthChanged);
      _authProvider = next..addListener(_handleAuthChanged);
    }
    _scheduleLoginRewardSync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _scheduleExternalRequestDrain();
      _scheduleLoginRewardSync(force: true);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _authProvider?.removeListener(_handleAuthChanged);
    _modaoPaymentBridge.stop();
    super.dispose();
  }

  void _scheduleExternalRequestDrain() {
    _externalRequestDrainRequested = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_drainPendingExternalRequests());
    });
  }

  Future<void> _runInitialExternalFlowAndStartupChecks() async {
    await _drainPendingExternalRequests();
    if (mounted) await _runStartupChecks();
  }

  Future<void> _drainPendingExternalRequests() async {
    if (_externalRequestDrainRunning || !mounted) return;
    if (_authProvider == null) {
      _scheduleExternalRequestDrain();
      return;
    }
    _externalRequestDrainRunning = true;
    try {
      var continueDraining = true;
      while (continueDraining && mounted) {
        _externalRequestDrainRequested = false;
        if (!mounted) return;
        final navigator = Navigator.of(context, rootNavigator: true);
        final authorization = await _takePendingModaoAuthorizationSafely();
        if (authorization != null && mounted) {
          await navigator.push<void>(
            MaterialPageRoute<void>(
              settings: const RouteSettings(name: '/games/modao/authorize'),
              builder: (_) => ModaoSsoAuthorizationScreen(
                request: authorization,
                bridge: _modaoPaymentBridge,
              ),
            ),
          );
          if (!mounted) return;
          continueDraining = await _modaoPaymentBridge
              .acknowledgeSsoAuthorizationRequest(authorization);
          continue;
        }

        final payment = await _takePendingModaoPaymentSafely();
        if (payment != null && mounted) {
          await navigator.push<void>(
            MaterialPageRoute<void>(
              settings: const RouteSettings(name: '/games/modao/payment'),
              builder: (_) => ModaoPaymentScreen(
                request: payment,
                bridge: _modaoPaymentBridge,
              ),
            ),
          );
          if (!mounted) return;
          continueDraining = await _modaoPaymentBridge
              .acknowledgePaymentRequest(payment);
          continue;
        }
        continueDraining = _externalRequestDrainRequested;
      }
    } catch (_) {
      // Requests remain persisted until their route finishes and is acknowledged.
    } finally {
      _externalRequestDrainRunning = false;
    }
    if (mounted && _externalRequestDrainRequested) {
      _scheduleExternalRequestDrain();
    }
  }

  Future<ModaoSsoAuthorizationRequest?>
  _takePendingModaoAuthorizationSafely() async {
    try {
      return await _modaoPaymentBridge.takePendingSsoAuthorizationRequest();
    } catch (_) {
      return null;
    }
  }

  Future<ModaoPaymentRequest?> _takePendingModaoPaymentSafely() async {
    try {
      return await _modaoPaymentBridge.takePendingRequest();
    } catch (_) {
      return null;
    }
  }

  Future<void> _runStartupChecks() async {
    try {
      final bootstrapFuture = _loadAppBootstrap();
      await _checkStartupUpdate();
      await _checkStartupAnnouncement();
      await bootstrapFuture;
    } finally {
      _startupChecksCompleted = true;
      _scheduleLoginRewardSync();
    }
  }

  void _handleAuthChanged() => _scheduleLoginRewardSync();

  void _scheduleLoginRewardSync({bool force = false}) {
    if (!mounted || !_startupChecksCompleted) return;
    final auth = _authProvider;
    if (auth == null || auth.isLoading || !auth.isLoggedIn) {
      if (auth == null || !auth.isLoggedIn) _lastLoginRewardToken = '';
      return;
    }
    if (_loginRewardSyncRunning) {
      _loginRewardResyncRequested =
          _loginRewardResyncRequested ||
          force ||
          _lastLoginRewardToken != auth.token;
      return;
    }
    if (!force && _lastLoginRewardToken == auth.token) return;
    _lastLoginRewardToken = auth.token;
    unawaited(_syncLoginRewards(auth.token));
  }

  Future<void> _syncLoginRewards(String token) async {
    _loginRewardSyncRunning = true;
    try {
      final result = await _loginRewardService.sync(token: token);
      if (!mounted || _authProvider?.token != token) return;
      final auth = _authProvider;
      final user = auth?.user;
      if (auth != null &&
          user != null &&
          user.growth.sakuraCoins != result.balance) {
        await auth.updateCachedUser(
          user.copyWith(
            growth: user.growth.copyWith(sakuraCoins: result.balance),
          ),
        );
        if (!mounted || _authProvider?.token != token) return;
      }
      for (final notice in result.items) {
        if (!mounted || _authProvider?.token != token) break;
        await _showLoginRewardNotice(notice);
        if (!mounted || _authProvider?.token != token) break;
        try {
          await _loginRewardService.acknowledge(
            token: token,
            noticeId: notice.id,
          );
        } catch (_) {
          // Keep the notice pending so it is shown again after the next sync.
          break;
        }
      }
    } catch (_) {
      if (_lastLoginRewardToken == token) _lastLoginRewardToken = '';
    } finally {
      _loginRewardSyncRunning = false;
      if (_loginRewardResyncRequested) {
        _loginRewardResyncRequested = false;
        _scheduleLoginRewardSync(force: true);
      }
    }
  }

  Future<void> _showLoginRewardNotice(LoginRewardNotice notice) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.redeem_outlined),
        title: Text(notice.title.isEmpty ? '登录赠礼' : notice.title),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (notice.content.isNotEmpty) Text(notice.content),
                if (notice.content.isNotEmpty) const SizedBox(height: 16),
                Text(
                  '已到账 +${notice.coinsAwarded} 樱花币',
                  style: Theme.of(dialogContext).textTheme.titleMedium
                      ?.copyWith(
                        color: Theme.of(dialogContext).colorScheme.primary,
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ],
            ),
          ),
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

  Future<void> _openActiveTtsReader() async {
    final ttsProvider = context.read<TtsProvider>();
    final novel = ttsProvider.activeNovel;
    final chapters = ttsProvider.activeChapters;
    final chapterIndex = ttsProvider.activeChapterIndex;
    if (novel == null ||
        chapters.isEmpty ||
        chapterIndex < 0 ||
        chapterIndex >= chapters.length) {
      return;
    }

    if (_currentIndex != 0) {
      setState(() {
        _visitedTabIndexes.add(0);
        _currentIndex = 0;
      });
      await WidgetsBinding.instance.endOfFrame;
    }
    if (!mounted ||
        _topRoutesByTab[0]?.settings.name == ReadingScreen.routeName) {
      return;
    }

    final readingProvider = context.read<ReadingProvider>();
    readingProvider
      ..setCurrentNovel(novel)
      ..setChapters(chapters)
      ..setCurrentChapter(chapters[chapterIndex]);
    final contentLength = ttsProvider.activeChapterContent.length;
    final startPosition = ttsProvider.currentStartOffset
        .clamp(0, contentLength)
        .toInt();
    await _navigatorKeys[0].currentState?.push<void>(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: ReadingScreen.routeName),
        builder: (_) => ReadingScreen(
          novel: novel,
          chapters: chapters,
          startChapterIndex: chapterIndex,
          startCharPosition: startPosition,
          startScrollPosition: contentLength == 0
              ? 0
              : startPosition / contentLength,
        ),
      ),
    );
  }

  Future<void> _checkStartupUpdate() async {
    if (_didCheckStartupUpdate) return;
    _didCheckStartupUpdate = true;
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;

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
        return const VideoScreen();
      case 4:
        return const ProfileScreen();
      default:
        return const SearchScreen(autofocus: false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final useNavigationRail = MediaQuery.sizeOf(context).width >= 720;
    final hideNav = _hideBottomNavByTab[_currentIndex];
    final topRoute = _topRoutesByTab[_currentIndex];
    final showingReader = topRoute?.settings.name == ReadingScreen.routeName;
    final showMiniPlayer = topRoute is PageRoute<dynamic> && !showingReader;
    final pages = IndexedStack(
      index: _currentIndex,
      children: List.generate(
        5,
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
        body: Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fill(
              child: useNavigationRail && !hideNav
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
                                icon: Icon(Icons.live_tv_outlined),
                                label: Text('影视'),
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
            ),
            if (showMiniPlayer)
              Positioned(
                left: useNavigationRail && !hideNav ? 77 : 0,
                right: 0,
                bottom: 0,
                child: TtsMiniPlayer(
                  onOpenReader: () => unawaited(_openActiveTtsReader()),
                ),
              ),
          ],
        ),
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
                    icon: Icon(Icons.live_tv_outlined),
                    label: '影视',
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
  _TabRouteObserver({required this.onChanged, required this.onTopRouteChanged});

  final ValueChanged<bool> onChanged;
  final ValueChanged<Route<dynamic>?> onTopRouteChanged;
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
    onTopRouteChanged(_routes.isEmpty ? null : _routes.last);
  }

  void reset() {
    _routes.clear();
    _emit();
  }
}
