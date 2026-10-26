import 'package:flutter/material.dart';

import 'package:archespace_mobile/src/features/auth/domain/password_policy.dart';

/// The login password rules under a new-password field, each ticked off while
/// typing, so they are known before submitting (as on the web).
class PasswordRules extends StatelessWidget {
  const PasswordRules({super.key, required this.password});

  final String password;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: 'Password needs',
      child: Wrap(
        spacing: 10,
        runSpacing: 4,
        children: [
          for (final check in passwordChecks(password))
            Semantics(
              label: '${check.label}, ${check.ok ? 'done' : 'missing'}',
              excludeSemantics: true,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    check.ok ? Icons.check : Icons.circle_outlined,
                    size: check.ok ? 14 : 8,
                    color: check.ok ? scheme.primary : scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 3),
                  Text(
                    check.label,
                    style: TextStyle(
                      fontSize: 12,
                      color: check.ok
                          ? scheme.primary
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
