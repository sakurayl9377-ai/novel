import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'config/theme.dart';
import 'services/storage_service.dart';
import 'services/tts_media_control_service.dart';
import 'providers/bookshelf_provider.dart';
import 'providers/book_source_provider.dart';
import 'providers/reading_provider.dart';
import 'providers/tts_provider.dart';
import 'screens/anime_screen.dart';
import 'screens/manga_reader_screen.dart';
import 'screens/manga_screen.dart';
import 'screens/reading_screen.dart';
import 'screens/search_screen.dart';
import 'screens/settings_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 初始化存储服务
  final storageService = StorageService();
  await storageService.init();
  final ttsMediaControlService = await TtsMediaControlService.init();

  // 设置状态栏样式
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
    ),
  );

  runApp(NovelApp(ttsMediaControlService: ttsMediaControlService));
}

class NovelApp extends StatefulWidget {
  const NovelApp({super.key, this.ttsMediaControlService});

  final TtsMediaControlService? ttsMediaControlService;

  @override
  State<NovelApp> createState() => _NovelAppState();
}

class _NovelAppState extends State<NovelApp> {
  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => BookshelfProvider()),
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
  int _currentIndex = 0;
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
  }

  void _selectTab(int index) {
    if (index == _currentIndex) return;
    setState(() {
      _routeObservers[index].reset();
      _hideBottomNavByTab[index] = false;
      _navigatorKeys[index] = GlobalKey<NavigatorState>();
      _currentIndex = index;
    });
  }

  Future<void> _handleBackNavigation() async {
    final navigator = _navigatorKeys[_currentIndex].currentState;
    await navigator?.maybePop();
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
        return const SettingsScreen();
      default:
        return const SearchScreen(autofocus: false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<void>(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        unawaited(_handleBackNavigation());
      },
      child: Scaffold(
        body: IndexedStack(
          index: _currentIndex,
          children: List.generate(4, _buildTabNavigator),
        ),
        bottomNavigationBar: _hideBottomNavByTab[_currentIndex]
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
    onChanged(
      _routes.any((route) {
        final name = route.settings.name;
        return name == ReadingScreen.routeName ||
            name == MangaReaderScreen.routeName;
      }),
    );
  }

  void reset() {
    _routes.clear();
    _emit();
  }
}
