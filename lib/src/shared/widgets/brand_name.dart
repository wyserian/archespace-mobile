import 'package:flutter/material.dart';

/// The name as text, as on the web and in the emails: "ARCHESPACE" in caps,
/// with ARCHE in the accent colour.
class BrandName extends StatelessWidget {
  const BrandName({super.key, this.fontSize = 24});

  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: 'ARCHE',
            style: TextStyle(color: scheme.primary),
          ),
          const TextSpan(text: 'SPACE'),
        ],
      ),
      semanticsLabel: 'ArcheSpace',
      style: TextStyle(
        fontSize: fontSize,
        fontWeight: FontWeight.w700,
        letterSpacing: fontSize * 0.03,
        color: scheme.onSurface,
      ),
    );
  }
}
