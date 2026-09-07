import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/field_user.dart';

/// Thrown when credentials are rejected or the sign-in call fails.
///
/// The prototype draws no error state, so the copy here is ASSUMED — see
/// ASSUMPTIONS.md. It follows the product's own tone: say what went wrong and
/// what to do, no apology.
class AuthException implements Exception {
  const AuthException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// The boundary a real Asite auth client will implement.
///
/// Nothing above this line knows how credentials are exchanged. When the API
/// arrives, add AsiteAuthRepository here and change one provider override.
abstract interface class AuthRepository {
  Future<FieldUser> signIn({
    required String email,
    required String password,
    required bool rememberDevice,
  });

  Future<void> signOut();
}

/// PHASE 1 MOCK.
///
/// Accepts any well-formed @asite.com address with a password of 8+ characters,
/// so the flow is walkable on a device with no backend. Any other address is
/// rejected, which gives QA a real error path to test.
class MockAuthRepository implements AuthRepository {
  MockAuthRepository({this.latency = const Duration(milliseconds: 900)});

  final Duration latency;

  @override
  Future<FieldUser> signIn({
    required String email,
    required String password,
    required bool rememberDevice,
  }) async {
    await Future<void>.delayed(latency);

    if (!email.toLowerCase().endsWith('@asite.com')) {
      throw const AuthException(
        'That is not an Asite account. Use the address your site office issued.',
      );
    }
    if (password.length < 8) {
      throw const AuthException(
        'Email or password not recognised. Check both and try again.',
      );
    }

    final String local = email.split('@').first;
    return FieldUser(
      id: 'usr_${local.hashCode.abs()}',
      email: email,
      displayName: local.replaceAll('.', ' '),
    );
  }

  @override
  Future<void> signOut() async {
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
}

/// Override this in a ProviderScope to swap in the real client.
final authRepositoryProvider =
    Provider<AuthRepository>((ref) => MockAuthRepository());
