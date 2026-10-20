import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../features/auth/application/auth_provider.dart';
import '../features/auth/presentation/login_screen.dart';
import '../features/home/presentation/home_screen.dart';
import '../features/features/presentation/features_screen.dart';
import '../features/devices/presentation/devices_screen.dart';
import '../features/devices/presentation/device_detail_screen.dart';
import '../features/devices/presentation/har_device_screen.dart';
import '../features/devices/presentation/wifi_device_screen.dart';
import '../features/devices/presentation/env_device_screen.dart';
import '../features/demos/presentation/demos_screen.dart';
import '../features/live/presentation/live_screen.dart';
import '../features/pairing/presentation/pairing_screen.dart';
import '../features/setup/presentation/setup_screen.dart';
import '../features/setup/presentation/ap_recovery_screen.dart';
import '../features/calibrate/presentation/calibrate_screen.dart';
import '../features/chat/presentation/chat_screen.dart';
import '../features/context/presentation/context_home_screen.dart';
import '../features/context/presentation/entity_detail_screen.dart';
import '../features/context/presentation/fleet_map.dart';
import '../features/context/presentation/infer_screen.dart';
import '../features/context/presentation/relations_screen.dart';
import '../features/context/presentation/space_detail_screen.dart';
import '../features/timeline/presentation/timeline_screen.dart';
import '../features/earbuds/presentation/earbuds_detail_screen.dart';
import '../features/watch/presentation/enroll_screen.dart';
import '../features/watch/presentation/watch_screen.dart';
import '../features/watch/presentation/pinetime_detail_screen.dart';
import '../features/events/presentation/events_screen.dart';
import '../features/actions/presentation/actions_screen.dart';
import '../features/actuators/presentation/actuators_screen.dart';
import '../features/research/presentation/research_screen.dart';
import '../features/contact/presentation/contact_screen.dart';
import '../features/settings/presentation/settings_screen.dart';
import '../features/legal/presentation/legal_screen.dart';
import '../features/shop/presentation/shop_screen.dart';
import '../features/plans/presentation/plans_screen.dart';
import '../features/community/presentation/community_screen.dart';
import '../shared/widgets/app_scaffold.dart';
import '../shared/widgets/page_scaffold.dart';

/// Route paths
class AppRoutes {
  static const String home = '/';
  static const String login = '/login';
  static const String features = '/features';
  static const String devices = '/devices';
  static const String pair = '/pair';
  static const String demos = '/demos';
  static const String shop = '/shop';
  static const String plans = '/plans';
  static const String community = '/community';
  static const String research = '/research';
  static const String contact = '/contact';
  static const String settings = '/settings';
  static const String legal = '/legal';
  static const String watch = '/watch';
  static const String events = '/events';
  static const String actuators = '/actuators';
  static const String context = '/context';
  static const String setup = '/setup';
  static const String calibrate = '/calibrate';
  static const String chat = '/chat';
  static const String actions = '/actions';
}

/// Router is a provider so redirects react to auth state changes.
final appRouterProvider = Provider<GoRouter>((ref) {
  final auth = ref.watch(authProvider);

  return GoRouter(
    initialLocation: AppRoutes.home,
    redirect: (context, state) {
      if (auth.isLoading) return null;
      final onLogin = state.uri.path == AppRoutes.login;
      if (!auth.isAuthenticated && !onLogin) return AppRoutes.login;
      if (auth.isAuthenticated && onLogin) return AppRoutes.home;
      return null;
    },
    routes: [
      GoRoute(
        path: AppRoutes.login,
        builder: (context, state) => const LoginScreen(),
      ),

      // Shell — bottom navigation tabs
      ShellRoute(
        builder: (context, state, child) => AppScaffold(child: child),
        routes: [
          GoRoute(
            path: AppRoutes.devices,
            pageBuilder: (context, state) => const NoTransitionPage(
              child: DevicesScreen(),
            ),
          ),
          GoRoute(
            path: AppRoutes.research,
            pageBuilder: (context, state) => const NoTransitionPage(
              child: ResearchScreen(),
            ),
          ),
          GoRoute(
            path: AppRoutes.settings,
            pageBuilder: (context, state) => const NoTransitionPage(
              child: SettingsScreen(),
            ),
          ),
          GoRoute(
            path: AppRoutes.watch,
            pageBuilder: (context, state) => const NoTransitionPage(
              child: WatchScreen(),
            ),
          ),
          GoRoute(
            path: AppRoutes.events,
            pageBuilder: (context, state) => const NoTransitionPage(
              child: EventsScreen(),
            ),
          ),
          GoRoute(
            path: AppRoutes.actuators,
            pageBuilder: (context, state) => const NoTransitionPage(
              child: ActuatorsScreen(),
            ),
          ),
          GoRoute(
            path: AppRoutes.home,
            pageBuilder: (context, state) => const NoTransitionPage(
              child: HomeScreen(),
            ),
          ),
          // Map tab — world fleet map that zooms into the floor plan.
          GoRoute(
            path: AppRoutes.context,
            pageBuilder: (context, state) => const NoTransitionPage(
              child: FleetMapScreen(),
            ),
          ),
          // Chat tab — assistant lives inside the shell so the nav bar
          // has its own destination icon.
          GoRoute(
            path: AppRoutes.chat,
            pageBuilder: (context, state) => const NoTransitionPage(
              child: ChatScreen(),
            ),
          ),
          // Actions tab — automations + actuators + context in one
          // tabbed surface.
          GoRoute(
            path: AppRoutes.actions,
            pageBuilder: (context, state) => const NoTransitionPage(
              child: ActionsScreen(),
            ),
          ),
        ],
      ),

      // Full-screen routes
      GoRoute(
        path: AppRoutes.pair,
        builder: (context, state) => const PairingScreen(),
      ),
      GoRoute(
        path: AppRoutes.setup,
        builder: (context, state) => const SetupScreen(),
      ),
      GoRoute(
        path: '/setup/ap',
        builder: (context, state) => const ApRecoveryScreen(),
      ),
      GoRoute(
        path: AppRoutes.calibrate,
        builder: (context, state) => const CalibrateScreen(),
      ),
      GoRoute(
        path: '/watch/enroll',
        builder: (context, state) => const EnrollScreen(),
      ),
      GoRoute(
        path: '/context/entities/:id',
        builder: (context, state) => EntityDetailScreen(
          entityId: Uri.decodeComponent(state.pathParameters['id']!),
        ),
      ),
      GoRoute(
        path: '/context/relations',
        builder: (context, state) => Scaffold(
          appBar: AppBar(title: const Text('BLE map')),
          body: const RelationsScreen(),
        ),
      ),
      GoRoute(
        path: '/context/spaces/:id',
        builder: (context, state) => SpaceDetailScreen(
          spaceId: state.pathParameters['id']!,
        ),
      ),
      GoRoute(
        path: '/context/home',
        builder: (context, state) => Scaffold(
          appBar: AppBar(title: const Text('Context')),
          body: const ContextHomeScreen(),
        ),
      ),
      GoRoute(
        path: '/context/infer',
        builder: (context, state) => Scaffold(
          appBar: AppBar(title: const Text('Infer')),
          body: const InferScreen(),
        ),
      ),
      GoRoute(
        path: '/context/timeline',
        builder: (context, state) => Scaffold(
          appBar: AppBar(title: const Text('Timeline')),
          body: const TimelineScreen(),
        ),
      ),
      GoRoute(
        path: '/watch/:bleId',
        builder: (context, state) => PinetimeDetailScreen(
          bleId: Uri.decodeComponent(state.pathParameters['bleId']!),
        ),
      ),
      GoRoute(
        path: '/earbuds/:bleId',
        builder: (context, state) => EarbudsDetailScreen(
          bleId: Uri.decodeComponent(state.pathParameters['bleId']!),
        ),
      ),
      GoRoute(
        path: '/devices/:id/live',
        builder: (context, state) =>
            LiveScreen(deviceId: state.pathParameters['id']!),
      ),

      // Marketing / info pages (drawer) — these screens were authored as
      // bare scroll views without a Scaffold; PageScaffold supplies the
      // app bar + back button for the pushed route.
      GoRoute(
        path: AppRoutes.features,
        builder: (context, state) =>
            const PageScaffold(title: 'Features', child: FeaturesScreen()),
      ),
      GoRoute(
        path: AppRoutes.demos,
        builder: (context, state) =>
            const PageScaffold(title: 'Demos', child: DemosScreen()),
      ),
      GoRoute(
        path: AppRoutes.shop,
        builder: (context, state) =>
            const PageScaffold(title: 'Shop', child: ShopScreen()),
      ),
      GoRoute(
        path: AppRoutes.plans,
        builder: (context, state) =>
            const PageScaffold(title: 'Plans', child: PlansScreen()),
      ),
      GoRoute(
        path: AppRoutes.community,
        builder: (context, state) =>
            const PageScaffold(title: 'Community', child: CommunityScreen()),
      ),
      GoRoute(
        path: AppRoutes.contact,
        builder: (context, state) => const ContactScreen(),
      ),
      GoRoute(
        path: AppRoutes.legal,
        builder: (context, state) => const LegalScreen(),
      ),
      GoRoute(
        path: '/devices/har',
        builder: (context, state) => const HarDeviceScreen(),
      ),
      GoRoute(
        path: '/devices/wifi',
        builder: (context, state) => const WifiDeviceScreen(),
      ),
      GoRoute(
        path: '/devices/env',
        builder: (context, state) => const EnvDeviceScreen(),
      ),
      // Device detail via the Brain node tunnel — declared last so the
      // literal /devices/{har,wifi,env} routes keep winning.
      GoRoute(
        path: '/devices/:id',
        builder: (context, state) =>
            DeviceDetailScreen(deviceId: state.pathParameters['id']!),
      ),
    ],
    errorBuilder: (context, state) => Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 64, color: Colors.red),
            const SizedBox(height: 16),
            Text('Page not found',
                style: Theme.of(context).textTheme.headlineMedium,),
            const SizedBox(height: 8),
            Text(state.uri.toString(),
                style: Theme.of(context).textTheme.bodyMedium,),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: () => context.go(AppRoutes.home),
              child: const Text('Go Home'),
            ),
          ],
        ),
      ),
    ),
  );
});
