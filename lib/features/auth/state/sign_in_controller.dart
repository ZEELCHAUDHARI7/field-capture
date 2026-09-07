import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/auth_repository.dart';
import '../models/field_user.dart';

/// Sign-in form state. Kept out of the widget so the screen stays declarative
/// and the submit path is unit-testable without pumping a widget.
class SignInState {
  const SignInState({
    this.submitting = false,
    this.rememberDevice = true,
    this.error,
    this.user,
  });

  final bool submitting;

  /// "Remember me is on by default — crews sign in once per device." (stated)
  final bool rememberDevice;

  final String? error;
  final FieldUser? user;

  bool get isSignedIn => user != null;

  SignInState copyWith({
    bool? submitting,
    bool? rememberDevice,
    String? error,
    bool clearError = false,
    FieldUser? user,
  }) {
    return SignInState(
      submitting: submitting ?? this.submitting,
      rememberDevice: rememberDevice ?? this.rememberDevice,
      error: clearError ? null : (error ?? this.error),
      user: user ?? this.user,
    );
  }
}

class SignInController extends Notifier<SignInState> {
  @override
  SignInState build() => const SignInState();

  void setRememberDevice(bool value) {
    state = state.copyWith(rememberDevice: value);
  }

  void clearError() {
    if (state.error != null) state = state.copyWith(clearError: true);
  }

  /// Returns true when the user is signed in, so the screen can navigate.
  Future<bool> submit({required String email, required String password}) async {
    if (state.submitting) return false;
    state = state.copyWith(submitting: true, clearError: true);

    try {
      final FieldUser user =
          await ref.read(authRepositoryProvider).signIn(
                email: email.trim(),
                password: password,
                rememberDevice: state.rememberDevice,
              );
      state = state.copyWith(submitting: false, user: user);
      return true;
    } on AuthException catch (e) {
      state = state.copyWith(submitting: false, error: e.message);
      return false;
    } catch (_) {
      state = state.copyWith(
        submitting: false,
        error: 'Could not reach Asite. Check your connection and try again.',
      );
      return false;
    }
  }
}

final NotifierProvider<SignInController, SignInState> signInControllerProvider =
    NotifierProvider<SignInController, SignInState>(SignInController.new);
