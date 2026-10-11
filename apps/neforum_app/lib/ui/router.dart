import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'accounts/accounts_screen.dart';
import 'accounts/add_account_screen.dart';
import 'activity/activity_screen.dart';
import 'activity/post_detail_screen.dart';
import 'compose/compose_screen.dart';
import 'queue/queue_screen.dart';
import 'settings/settings_screen.dart';
import 'shell/app_shell.dart';

/// Root navigator: dialogs and sheets opened by services (hand-off, paste
/// code) attach here so they show above every tab.
final rootNavigatorKey = GlobalKey<NavigatorState>(debugLabel: 'root');

/// The five top-level sections, in navigation order.
enum AppSection {
  compose('/compose', 'Compose', Icons.edit_square, Icons.edit_square),
  queue('/queue', 'Queue', Icons.event_note_outlined, Icons.event_note_rounded),
  activity('/activity', 'Activity', Icons.insights_outlined, Icons.insights_rounded),
  accounts('/accounts', 'Accounts', Icons.hub_outlined, Icons.hub_rounded),
  settings('/settings', 'Settings', Icons.tune_outlined, Icons.tune_rounded);

  const AppSection(this.path, this.label, this.icon, this.selectedIcon);
  final String path;
  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

final routerProvider = Provider<GoRouter>((ref) {
  final router = GoRouter(
    navigatorKey: rootNavigatorKey,
    initialLocation: AppSection.compose.path,
    routes: [
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) => AppShell(shell: shell),
        branches: [
          StatefulShellBranch(routes: [
            GoRoute(
              path: AppSection.compose.path,
              pageBuilder: (context, state) => NoTransitionPage(
                child: ComposeScreen(editPostId: state.uri.queryParameters['post']),
              ),
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(path: AppSection.queue.path, pageBuilder: (context, state) => const NoTransitionPage(child: QueueScreen())),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: AppSection.activity.path,
              pageBuilder: (context, state) => const NoTransitionPage(child: ActivityScreen()),
              routes: [
                GoRoute(path: 'post/:id', builder: (context, state) => PostDetailScreen(postId: state.pathParameters['id']!)),
              ],
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: AppSection.accounts.path,
              pageBuilder: (context, state) => const NoTransitionPage(child: AccountsScreen()),
              routes: [
                GoRoute(
                  path: 'add',
                  builder: (context, state) => AddAccountScreen(initialPlatformId: state.uri.queryParameters['platform']),
                ),
              ],
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(path: AppSection.settings.path, pageBuilder: (context, state) => const NoTransitionPage(child: SettingsScreen())),
          ]),
        ],
      ),
    ],
  );
  ref.onDispose(router.dispose);
  return router;
});
