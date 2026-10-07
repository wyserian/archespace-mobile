import 'package:flutter/material.dart';

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
                  // The name as on the web and in the emails: caps, ARCHE in
                  // the brand mint (deeper on light for contrast).
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: 'ARCHE',
                          style: TextStyle(
                            color: theme.brightness == Brightness.dark
                                ? const Color(0xFF32D3AA)
                                : const Color(0xFF0B7F64),
                          ),
                        ),
                        const TextSpan(text: 'SPACE'),
                      ],
                    ),
                    semanticsLabel: 'ArcheSpace',
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.72,
                      color: scheme.onSurface,
                    ),
                  ),
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
