import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/constants/app_constants.dart';
import '../../core/theme/app_colors.dart';
import 'cell_logo.dart';
import '../../features/auth/application/auth_provider.dart';
import '../../routes/app_router.dart';

/// Main scaffold — M3 NavigationBar + grouped drawer.
class AppScaffold extends ConsumerWidget {
  const AppScaffold({required this.child, super.key});

  final Widget child;

  static const _tabs = [
    (icon: Icons.home_outlined, active: Icons.home, label: 'Home'),
    (
      icon: Icons.map_outlined,
      active: Icons.map,
      label: 'Map'
    ),
    (
      icon: Icons.auto_awesome_outlined,
      active: Icons.auto_awesome,
      label: 'Chat'
    ),
    (
      icon: Icons.bolt_outlined,
      active: Icons.bolt,
      label: 'Actions'
    ),
    (
      icon: Icons.devices_outlined,
      active: Icons.devices,
      label: 'Devices'
    ),
    (
      icon: Icons.settings_outlined,
      active: Icons.settings,
      label: 'Settings'
    ),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);
    final location = GoRouterState.of(context).uri.path;
    // The chat surface carries its own app bar + composer — supplying
    // the shell's chrome here would double the headers.
    final isChat = location == AppRoutes.chat;
    return Scaffold(
      appBar: isChat
          ? null
          : AppBar(
              title: const Row(
                children: [
                  CellLogo(size: 30),
                  SizedBox(width: 8),
                  Text(AppConstants.appName),
                ],
              ),
              actions: [
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Center(
                    child: _PlanBadge(plan: auth.plan),
                  ),
                ),
              ],
            ),
      drawer: isChat ? null : _buildDrawer(context, ref, auth),
      body: child,
      bottomNavigationBar: _buildNavBar(context),
      floatingActionButton: isChat
          ? null
          : FloatingActionButton(
              heroTag: 'assistant',
              tooltip: 'Assistant',
              onPressed: () => context.push(AppRoutes.chat),
              child: const Icon(Icons.auto_awesome),
            ),
    );
  }

  Widget _buildNavBar(BuildContext context) {
    final location = GoRouterState.of(context).uri.path;
    final selected = _getSelectedIndex(location);
    return NavigationBar(
      selectedIndex: selected,
      onDestinationSelected: (i) => _onItemTapped(i, context),
      destinations: [
        for (final t in _tabs)
          NavigationDestination(
            icon: Icon(t.icon),
            selectedIcon: Icon(t.active),
            label: t.label,
          ),
      ],
    );
  }

  Widget _buildDrawer(
      BuildContext context, WidgetRef ref, AuthState auth,) {
    return Drawer(
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          // Header — identity block.
          Container(
            color: AppColors.primaryBlue,
            padding: EdgeInsets.only(
              top: MediaQuery.of(context).padding.top + 16,
              left: 16, right: 16, bottom: 16,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const CellLogo(size: 44, brightness: Brightness.dark),
                const SizedBox(height: 10),
                Text(
                  auth.username ?? AppConstants.appName,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Row(children: [
                  _PlanBadge(plan: auth.plan, onDark: true),
                ],),
              ],
            ),
          ),

          const _DrawerLabel('System'),
          _item(context, Icons.watch_outlined, 'Watch (PineTime)',
              () => context.go(AppRoutes.watch),),
          _item(context, Icons.toggle_on_outlined, 'Actions · automation · context',
              () => context.go(AppRoutes.actions),),
          _item(context, Icons.bolt_outlined, 'Activity feed',
              () => context.go(AppRoutes.events),),
          _item(context, Icons.science_outlined, 'Research & models',
              () => context.go(AppRoutes.research),),
          _item(context, Icons.insights_outlined, 'Context & entities',
              () => context.push('/context/home'),),
          _item(context, Icons.auto_awesome, 'Context inference (LLM)',
              () => context.push('/context/infer'),),

          const _DrawerLabel('Setup & tools'),
          _item(context, Icons.add_link, 'Pair a device',
              () => context.push(AppRoutes.pair),),
          _item(context, Icons.qr_code_scanner, 'Set up a node',
              () => context.push(AppRoutes.setup),),
          _item(context, Icons.my_location, 'Calibrate a space',
              () => context.push(AppRoutes.calibrate),),
          _item(context, Icons.watch_outlined, 'Enroll a wearable',
              () => context.push('/watch/enroll'),),

          const Divider(height: 24),
          _item(context, Icons.policy_outlined, 'Privacy & terms',
              () => context.push(AppRoutes.legal),),
          ListTile(
            leading: const Icon(Icons.open_in_new),
            title: const Text('Open portal'),
            onTap: () => _launchUrl(AppConstants.portalUrl),
          ),
          ListTile(
            leading: const Icon(Icons.logout, color: Colors.redAccent),
            title:
                const Text('Sign out', style: TextStyle(color: Colors.redAccent)),
            onTap: () async {
              Navigator.pop(context);
              await ref.read(authProvider.notifier).logout();
              if (context.mounted) context.go(AppRoutes.login);
            },
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Text(
              'v${AppConstants.appVersion}',
              style: TextStyle(color: AppColors.textTertiaryLight, fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }

  Widget _item(
      BuildContext context, IconData icon, String label, void Function() go,) {
    return ListTile(
      dense: true,
      leading: Icon(icon, size: 22),
      title: Text(label),
      onTap: () {
        Navigator.pop(context);
        go();
      },
    );
  }

  int _getSelectedIndex(String location) {
    if (location.startsWith(AppRoutes.context)) return 1; // map
    if (location.startsWith(AppRoutes.chat)) return 2;
    if (location.startsWith(AppRoutes.actions) ||
        location.startsWith(AppRoutes.actuators) ||
        location.startsWith(AppRoutes.events)) {
      return 3;
    }
    if (location.startsWith(AppRoutes.devices)) return 4;
    if (location.startsWith(AppRoutes.settings)) return 5;
    return 0; // home, watch, research, actuators
  }

  void _onItemTapped(int index, BuildContext context) {
    switch (index) {
      case 0:
        context.go(AppRoutes.home);
      case 1:
        context.go(AppRoutes.context);
      case 2:
        context.go(AppRoutes.chat);
      case 3:
        context.go(AppRoutes.actions);
      case 4:
        context.go(AppRoutes.devices);
      case 5:
        context.go(AppRoutes.settings);
    }
  }

  Future<void> _launchUrl(String urlString) async {
    final uri = Uri.parse(urlString);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }
}

class _PlanBadge extends StatelessWidget {
  const _PlanBadge({required this.plan, this.onDark = false});
  final String plan;
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    final isFree = plan.toLowerCase() == 'free';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: onDark
            ? Colors.white.withValues(alpha: 0.2)
            : (isFree
                ? Theme.of(context).colorScheme.surfaceContainerHighest
                : AppColors.primaryBlue.withValues(alpha: 0.12)),
        borderRadius: BorderRadius.circular(20),
        border: onDark ? null : Border.all(color: AppColors.primaryBlue.withValues(alpha: 0.4)),
      ),
      child: Text(
        plan.toUpperCase(),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
          color: onDark ? Colors.white : AppColors.primaryBlue,
        ),
      ),
    );
  }
}

class _DrawerLabel extends StatelessWidget {
  const _DrawerLabel(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 2),
        child: Text(
          text.toUpperCase(),
          style: TextStyle(
            fontSize: 10.5,
            letterSpacing: 1.2,
            fontWeight: FontWeight.w700,
            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.8),
          ),
        ),
      );
}
