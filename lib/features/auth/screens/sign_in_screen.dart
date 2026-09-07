import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/app_sizes.dart';
import '../../../core/routing/routes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_text_field.dart';
import '../../../core/widgets/brand_mark.dart';
import '../state/sign_in_controller.dart';

/// Prototype screen 01 — Sign in.
///
/// "Asite credentials sign the user into the field app. Projects, calibrations
/// and plans download for offline use straight after sign-in."
class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key});

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _email = TextEditingController();
  final TextEditingController _password = TextEditingController();

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    if (!(_formKey.currentState?.validate() ?? false)) return;

    final bool signedIn = await ref
        .read(signInControllerProvider.notifier)
        .submit(email: _email.text, password: _password.text);

    if (signedIn && mounted) {
      context.go(Routes.projects);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final SignInState state = ref.watch(signInControllerProvider);

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: AppColors.chrome,
        resizeToAvoidBottomInset: true,
        body: Column(
          children: <Widget>[
            _Hero(theme: theme),
            Expanded(
              child: Container(
                width: double.infinity,
                decoration: const BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.vertical(
                    top: Radius.circular(AppSizes.radiusSheet),
                  ),
                ),
                child: SafeArea(
                  top: false,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(
                      AppSizes.xl,
                      AppSizes.xxl,
                      AppSizes.xl,
                      AppSizes.xl,
                    ),
                    child: AutofillGroup(
                      child: Form(
                        key: _formKey,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            if (state.error != null) ...<Widget>[
                              _ErrorBanner(message: state.error!),
                              const SizedBox(height: AppSizes.lg),
                            ],
                            AppTextField(
                              label: 'Email',
                              controller: _email,
                              hintText: 'name@asite.com',
                              keyboardType: TextInputType.emailAddress,
                              textInputAction: TextInputAction.next,
                              autofillHints: const <String>[
                                AutofillHints.username,
                                AutofillHints.email,
                              ],
                              enabled: !state.submitting,
                              validator: _validateEmail,
                            ),
                            const SizedBox(height: AppSizes.lg),
                            AppTextField(
                              label: 'Password',
                              controller: _password,
                              obscureText: true,
                              textInputAction: TextInputAction.done,
                              autofillHints: const <String>[
                                AutofillHints.password,
                              ],
                              enabled: !state.submitting,
                              validator: _validatePassword,
                              onFieldSubmitted: (_) => _submit(),
                            ),
                            const SizedBox(height: AppSizes.md),
                            _RememberMe(
                              value: state.rememberDevice,
                              enabled: !state.submitting,
                              onChanged: ref
                                  .read(signInControllerProvider.notifier)
                                  .setRememberDevice,
                            ),
                            const SizedBox(height: AppSizes.xl),
                            AppButton(
                              label: 'Sign in',
                              busy: state.submitting,
                              onPressed: _submit,
                            ),
                            const SizedBox(height: AppSizes.lg),
                            Text(
                              'Use your Asite credentials. Projects and plans '
                              'download for offline use once signed in.',
                              textAlign: TextAlign.center,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: AppColors.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// ASSUMED — the prototype specifies no validation rules.
  String? _validateEmail(String? value) {
    final String email = (value ?? '').trim();
    if (email.isEmpty) return 'Enter your Asite email address.';
    if (!email.contains('@') || !email.contains('.')) {
      return 'That does not look like an email address.';
    }
    return null;
  }

  String? _validatePassword(String? value) {
    if ((value ?? '').isEmpty) return 'Enter your password.';
    return null;
  }
}

class _Hero extends StatelessWidget {
  const _Hero({required this.theme});
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSizes.xl,
          AppSizes.xxl,
          AppSizes.xl,
          AppSizes.xxl,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const BrandMark(size: 44),
            const SizedBox(height: AppSizes.lg),
            Text(
              'Field Capture',
              style: theme.textTheme.displaySmall
                  ?.copyWith(color: AppColors.onChrome),
            ),
            const SizedBox(height: AppSizes.xs),
            Text(
              'Site progress monitoring · 360° capture',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: AppColors.onChromeMuted),
            ),
          ],
        ),
      ),
    );
  }
}

class _RememberMe extends StatelessWidget {
  const _RememberMe({
    required this.value,
    required this.onChanged,
    required this.enabled,
  });

  final bool value;
  final ValueChanged<bool> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: enabled ? () => onChanged(!value) : null,
      borderRadius: BorderRadius.circular(AppSizes.radiusButton),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSizes.xs),
        child: Row(
          children: <Widget>[
            SizedBox(
              height: AppSizes.minTouchTarget,
              width: AppSizes.minTouchTarget,
              child: Checkbox(
                value: value,
                onChanged: enabled
                    ? (bool? next) => onChanged(next ?? false)
                    : null,
              ),
            ),
            const SizedBox(width: AppSizes.xs),
            Expanded(
              child: Text(
                'Remember me on this device',
                style: Theme.of(context).textTheme.bodyLarge,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSizes.md),
      decoration: BoxDecoration(
        color: AppColors.dangerContainer,
        borderRadius: BorderRadius.circular(AppSizes.radiusButton),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Icon(
            Icons.error_outline,
            size: 18,
            color: AppColors.onDangerContainer,
          ),
          const SizedBox(width: AppSizes.sm),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: AppColors.onDangerContainer,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}
