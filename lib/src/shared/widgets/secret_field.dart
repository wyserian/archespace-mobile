import 'package:flutter/material.dart';

/// A password or vault PIN field: hidden as typed, with an eye to show it.
/// Never autocorrected or suggested.
class SecretField extends StatefulWidget {
  const SecretField({
    super.key,
    required this.controller,
    required this.label,
    this.enabled = true,
    this.onChanged,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final String label;
  final bool enabled;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  @override
  State<SecretField> createState() => _SecretFieldState();
}

class _SecretFieldState extends State<SecretField> {
  bool _obscure = true;

  @override
  Widget build(BuildContext context) => TextField(
    controller: widget.controller,
    obscureText: _obscure,
    enabled: widget.enabled,
    autocorrect: false,
    enableSuggestions: false,
    onChanged: widget.onChanged,
    onSubmitted: widget.onSubmitted,
    decoration: InputDecoration(
      labelText: widget.label,
      suffixIcon: IconButton(
        icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
        tooltip: _obscure ? 'Show' : 'Hide',
        onPressed: () => setState(() => _obscure = !_obscure),
      ),
    ),
  );
}
