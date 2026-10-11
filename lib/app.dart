import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/theme/app_theme.dart';
import 'features/observe/data/observation_service.dart';
import 'features/settings/application/app_settings.dart';
import 'features/watch/application/watch_providers.dart';
import 'routes/app_router.dart';

class ThothcraftApp extends ConsumerStatefulWidget {
  const ThothcraftApp({super.key});

  @override
  ConsumerState<ThothcraftApp> createState() => _ThothcraftAppState();
}

class _ThothcraftAppState extends ConsumerState<ThothcraftApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Launch = foreground.
    ObservationService.instance.appLifecycleChanged(foreground: true);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    ObservationService.instance
        .appLifecycleChanged(foreground: state == AppLifecycleState.resumed);
  }

  @override
  Widget build(BuildContext context) {
    final themeMode = ref.watch(appSettingsProvider).valueOrNull?.themeMode ??
        ThemeMode.system;
    // Drive mobile evidence producers from the privacy toggles (Part 4/11).
    ref.watch(observationControllerProvider);
    // Build the watch manager at launch so paired watches re-link (and
    // the foreground relay restarts) without opening the watch screen.
    ref.watch(watchManagerProvider);
    return MaterialApp.router(
      title: 'Thothcraft',
      debugShowCheckedModeBanner: false,

      // Theme
      theme: AppTheme.lightTheme(),
      darkTheme: AppTheme.darkTheme(),
      themeMode: themeMode,
      
      // Routing (auth-aware via provider)
      routerConfig: ref.watch(appRouterProvider),
      
      // Localization
      supportedLocales: const [
        Locale('en', 'US'),
      ],
    );
  }
}
