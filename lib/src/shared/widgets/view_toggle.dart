import 'package:flutter/material.dart';

/// Grid / list switch, as on the web: a soft segmented control (no border),
/// the active side raised on the surface colour. [value] is 'grid' or 'list'.
class ViewToggle extends StatelessWidget {
  const ViewToggle({super.key, required this.value, required this.onChanged});

  final String value;
  final ValueChanged<String> onChanged;

  static const _options = [
    ('grid', 'Grid view', Icons.grid_view_outlined),
    ('list', 'List view', Icons.view_list_outlined),
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      container: true,
      label: 'View',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        // The track is drawn behind, so each side is tappable the full 48
        // height while the control looks 36 tall.
        child: Stack(
          children: [
            Positioned.fill(
              top: 6,
              bottom: 6,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final (id, label, icon) in _options)
                    _segment(scheme, id, label, icon, selected: value == id),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _segment(
    ColorScheme scheme,
    String id,
    String label,
    IconData icon, {
    required bool selected,
  }) {
    void pick() => onChanged(id);
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      child: Tooltip(
        message: label,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: pick,
          child: SizedBox(
            width: 42,
            height: 48,
            child: Center(
              child: Material(
                color: selected ? scheme.surface : Colors.transparent,
                elevation: selected ? 1 : 0,
                borderRadius: BorderRadius.circular(8),
                child: InkWell(
                  onTap: pick,
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    width: 42,
                    height: 32,
                    child: Icon(
                      icon,
                      size: 19,
                      color: selected
                          ? scheme.primary
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
