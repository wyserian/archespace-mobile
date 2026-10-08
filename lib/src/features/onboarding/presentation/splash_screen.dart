import 'package:flutter/material.dart';

import 'package:archespace_mobile/src/shared/widgets/brand_name.dart';

/// The app-open landing screen: the name and a one-line value prop, with a
/// single clear "Get started" action that continues to the sign-in /
/// create-account screen.
class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key, required this.onContinue});

  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const BrandName(),
                  const SizedBox(height: 10),
                  Text(
                    'Everything in One Encrypted Space',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 32),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: onContinue,
                      icon: const Icon(Icons.arrow_forward, size: 20),
                      label: const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: Text('Get started'),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
