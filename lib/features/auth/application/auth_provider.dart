import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/api/brain_client.dart';
import '../../../core/api/event_feed.dart';

class AuthState {
  const AuthState({
    this.isLoading = true,
    this.isAuthenticated = false,
    this.username,
    this.plan = 'free',
    this.entitlements = const {},
    this.error,
  });

  final bool isLoading;
  final bool isAuthenticated;
  final String? username;
  final String plan;
  final Map<String, dynamic> entitlements;
  final String? error;

  bool hasEntitlement(String key) => entitlements[key] == true;

  AuthState copyWith({
    bool? isLoading,
    bool? isAuthenticated,
    String? username,
    String? plan,
    Map<String, dynamic>? entitlements,
    String? error,
  }) =>
      AuthState(
        isLoading: isLoading ?? this.isLoading,
        isAuthenticated: isAuthenticated ?? this.isAuthenticated,
        username: username ?? this.username,
        plan: plan ?? this.plan,
        entitlements: entitlements ?? this.entitlements,
        error: error,
      );
}

class AuthNotifier extends StateNotifier<AuthState> {
  AuthNotifier() : super(const AuthState()) {
    _restore();
  }

  final _client = BrainClient.instance;

  Future<void> _restore() async {
    await _client.init();
    if (!_client.hasToken) {
      state = state.copyWith(isLoading: false);
      return;
    }
    try {
      final profile = await _client.getJson(
        '/profile',
        timeout: const Duration(seconds: 12),
      );
      state = state.copyWith(
        isLoading: false,
        isAuthenticated: true,
        username: profile['username'] as String?,
        plan: (profile['plan'] as String?) ?? 'free',
      );
      unawaited(_loadEntitlements());
      EventFeed.instance.start();
    } catch (e) {
      // Only a definitive 401/403 means the credential is dead — a
      // cold-start 500 or a flaky network must NOT wipe the stored
      // token (that was forcing re-login on every app launch).
      final status = e is DioException ? e.response?.statusCode : null;
      if (status == 401 || status == 403) {
        await _client.setToken(null);
        state = state.copyWith(isLoading: false);
        return;
      }
      // Transient failure — trust the persisted token, restore the
      // cached identity so the app opens logged-in, and refresh the
      // profile lazily next launch.
      final prefs = await SharedPreferences.getInstance();
      state = state.copyWith(
        isLoading: false,
        isAuthenticated: true,
        username: prefs.getString('settings.username'),
      );
      EventFeed.instance.start();
    }
  }

  Future<void> _loadEntitlements() async {
    try {
      final data = await _client.getJson('/account/entitlements');
      state = state.copyWith(
        plan: (data['plan'] as String?) ?? state.plan,
        entitlements:
            Map<String, dynamic>.from(data['entitlements'] as Map? ?? {}),
      );
    } catch (_) {/* best-effort */}
  }

  Future<bool> login(
    String username,
    String password, {
    bool rememberDevice = true,
  }) async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final data = await _client.login(username.trim(), password,
          persist: rememberDevice);
      final uname = data['username'] as String? ?? username.trim();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('settings.username', uname);
      state = state.copyWith(
        isLoading: false,
        isAuthenticated: true,
        username: uname,
        plan: (data['plan'] as String?) ?? 'free',
      );
      unawaited(_loadEntitlements());
      EventFeed.instance.start();
      return true;
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: 'Invalid username or password',
      );
      return false;
    }
  }

  Future<void> logout() async {
    EventFeed.instance.stop();
    await _client.logout();
    state = const AuthState(isLoading: false);
  }
}

final authProvider = StateNotifierProvider<AuthNotifier, AuthState>(
  (ref) => AuthNotifier(),
);
