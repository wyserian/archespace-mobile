import 'dart:async';

import 'package:flutter/material.dart';

import 'package:archespace_mobile/src/shared/data/expiry.dart';
import 'package:archespace_mobile/src/shared/widgets/tag_chip.dart';
import 'package:archespace_mobile/src/shared/widgets/tap_area.dart';

/// The result of the self-destruct sheet: the new time, or null to cancel it.
typedef ExpiryEdit = ({DateTime? at});

/// Set, change or cancel a space's or item's self-destruct time (expiry.dart):
/// a quick choice from now, or an exact day and time. When it passes, it's
/// deleted for good on every device. [space] words it for a space, which
/// takes its items and sub-spaces with it. Null when closed.
Future<ExpiryEdit?> showExpirySheet(
  BuildContext context, {
  required bool space,
  DateTime? initial,
}) => showModalBottomSheet<ExpiryEdit>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => _ExpirySheet(space: space, initial: initial),
);

class _ExpirySheet extends StatefulWidget {
  const _ExpirySheet({required this.space, this.initial});

  final bool space;
  final DateTime? initial;

  @override
  State<_ExpirySheet> createState() => _ExpirySheetState();
}

class _ExpirySheetState extends State<_ExpirySheet> {
  late DateTime _at =
      widget.initial?.toLocal() ?? DateTime.now().add(kExpiryPresets[1].$2);
  late String? _preset = widget.initial == null ? kExpiryPresets[1].$1 : null;

  bool get _valid =>
      _at.isAfter(DateTime.now().add(const Duration(minutes: 1)));

  Future<void> _pickDay() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _at.isBefore(now) ? now : _at,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: DateTime(now.year + 20),
    );
    if (picked == null) return;
    setState(() {
      _at = DateTime(
        picked.year,
        picked.month,
        picked.day,
        _at.hour,
        _at.minute,
      );
      _preset = null;
    });
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_at),
    );
    if (picked == null) return;
    setState(() {
      _at = DateTime(_at.year, _at.month, _at.day, picked.hour, picked.minute);
      _preset = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final loc = MaterialLocalizations.of(context);
    final when =
        '${loc.formatMediumDate(_at)}, '
        '${loc.formatTimeOfDay(TimeOfDay.fromDateTime(_at))}';
    final what = widget.space
        ? 'This space, with all its items and sub-spaces,'
        : 'This item';
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Self-destruct',
              style: textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final (label, after) in kExpiryPresets)
                  ChoiceChip(
                    label: Text(label),
                    selected: _preset == label,
                    showCheckmark: false,
                    onSelected: (_) => setState(() {
                      _preset = label;
                      _at = DateTime.now().add(after);
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _pickDay,
                    icon: const Icon(Icons.event_outlined, size: 18),
                    label: Text(loc.formatMediumDate(_at)),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _pickTime,
                    icon: const Icon(Icons.schedule, size: 18),
                    label: Text(
                      loc.formatTimeOfDay(TimeOfDay.fromDateTime(_at)),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text.rich(
              _valid
                  ? TextSpan(
                      children: [
                        TextSpan(text: '$what will be '),
                        TextSpan(
                          text: 'deleted permanently',
                          style: TextStyle(
                            color: scheme.error,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        TextSpan(
                          text:
                              ' on $when, from all your devices. It won\'t go '
                              'to the Bin and can\'t be restored.',
                        ),
                      ],
                    )
                  : const TextSpan(text: 'Pick a time in the future.'),
              style: textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                if (widget.initial != null)
                  TextButton(
                    onPressed: () =>
                        Navigator.pop<ExpiryEdit>(context, (at: null)),
                    child: const Text('Cancel self-destruct'),
                  ),
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Close'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _valid
                      ? () => Navigator.pop<ExpiryEdit>(context, (at: _at))
                      : null,
                  style: FilledButton.styleFrom(
                    backgroundColor: scheme.error,
                    foregroundColor: scheme.onError,
                  ),
                  child: Text(widget.initial == null ? 'Set' : 'Save'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A space's or item's self-destruct time as a chip beside its tags
/// ("Deletes in 5 h"), red with under a day left. Kept current as time
/// passes. Opens the self-destruct sheet when tappable.
class ExpiryChip extends StatefulWidget {
  const ExpiryChip({super.key, required this.at, this.onTap});

  final DateTime at;
  final VoidCallback? onTap;

  @override
  State<ExpiryChip> createState() => _ExpiryChipState();
}

class _ExpiryChipState extends State<ExpiryChip> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final soon = expiresSoon(widget.at);
    final color = soon ? scheme.error : scheme.onSurfaceVariant;
    final text = 'Deletes ${formatExpiresIn(widget.at)}';
    return Semantics(
      button: widget.onTap != null,
      label: 'Self-destructs: $text',
      excludeSemantics: true,
      child: TapArea(
        onTap: widget.onTap,
        minSize: kTagTapHeight,
        minWidth: 0,
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: BorderRadius.circular(kChipRadius),
          child: Container(
            height: kChipHeight,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: soon
                  ? color.withValues(alpha: 0.12)
                  : scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(kChipRadius),
              border: Border.all(
                color: soon
                    ? color.withValues(alpha: 0.35)
                    : scheme.outlineVariant,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.hourglass_bottom_rounded, size: 13, color: color),
                const SizedBox(width: 4),
                Text(
                  text,
                  style: TextStyle(
                    fontSize: kChipFontSize,
                    fontWeight: FontWeight.w600,
                    color: color,
                    height: 1,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
