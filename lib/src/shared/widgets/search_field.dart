import 'package:flutter/material.dart';

/// The app's one search field: a 48-tall pill on a soft surface, with a search
/// icon (or [leading], like the dashboard's menu button), the [hint] on the
/// left, and an x to clear once something is typed.
///
/// With [onTap] it's a button that opens search elsewhere (the dashboard);
/// otherwise it's the field itself, typed into via [controller].
class SearchField extends StatelessWidget {
  const SearchField({
    super.key,
    required this.hint,
    this.controller,
    this.focusNode,
    this.onChanged,
    this.onTap,
    this.autofocus = false,
    this.leading,
  }) : assert(onTap != null || controller != null);

  final String hint;
  final TextEditingController? controller;
  final FocusNode? focusNode;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onTap;
  final bool autofocus;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hintStyle = TextStyle(fontSize: 15, color: scheme.onSurfaceVariant);
    final lead =
        leading ??
        Padding(
          padding: const EdgeInsets.only(left: 16, right: 10),
          child: Icon(Icons.search, size: 20, color: scheme.onSurfaceVariant),
        );
    final field = controller;
    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(24),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        height: 48,
        child: Row(
          children: [
            lead,
            Expanded(
              child: onTap != null
                  ? InkWell(
                      onTap: onTap,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(hint, style: hintStyle),
                      ),
                    )
                  : TextField(
                      controller: field,
                      focusNode: focusNode,
                      autofocus: autofocus,
                      onChanged: onChanged,
                      style: const TextStyle(fontSize: 15),
                      textInputAction: TextInputAction.search,
                      decoration: InputDecoration.collapsed(
                        hintText: hint,
                        hintStyle: hintStyle,
                      ),
                    ),
            ),
            if (field != null && onTap == null)
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: field,
                builder: (context, value, _) => value.text.isEmpty
                    ? const SizedBox(width: 16)
                    : IconButton(
                        icon: Icon(
                          Icons.close,
                          size: 18,
                          color: scheme.onSurfaceVariant,
                        ),
                        tooltip: 'Clear search',
                        onPressed: () {
                          field.clear();
                          onChanged?.call('');
                        },
                      ),
              )
            else
              const SizedBox(width: 16),
          ],
        ),
      ),
    );
  }
}
