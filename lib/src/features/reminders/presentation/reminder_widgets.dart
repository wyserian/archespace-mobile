import 'dart:async';

import 'package:flutter/material.dart';

import 'package:archespace_mobile/src/features/items/domain/reminder.dart';

/// The result of the reminder sheet: the new reminder, or null to remove it.
typedef ReminderEdit = ({Reminder? reminder});

/// Set, change or remove an item's reminder: its name, when it first goes
/// off, and whether it goes off once, repeats until a day, or repeats until
/// turned off. Null when cancelled.
Future<ReminderEdit?> showReminderSheet(
  BuildContext context, {
  Reminder? initial,
}) => showModalBottomSheet<ReminderEdit>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => _ReminderSheet(initial: initial),
);

class _ReminderSheet extends StatefulWidget {
  const _ReminderSheet({this.initial});

  final Reminder? initial;

  @override
  State<_ReminderSheet> createState() => _ReminderSheetState();
}

class _ReminderSheetState extends State<_ReminderSheet> {
  late final String _today = Reminder.dayString(DateTime.now());
  late final Reminder _start = widget.initial ?? Reminder.initial();
  late final _name = TextEditingController(text: _start.name);
  late String _date = _start.date;
  late String _time = _start.time;
  late ReminderMode _mode = _start.mode;
  late ReminderEvery _every = _start.every;
  late String _until = _start.until ?? Reminder.addDays(_start.date, 30);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  /// The reminder as set, made valid (a repeat never ends before it starts).
  Reminder get _reminder => Reminder.fromJson({
    'name': _name.text,
    'date': _date,
    'time': _time,
    'mode': _mode.name,
    'every': _every.name,
    'until': _until,
  })!;

  DateTime _dayValue(String day) {
    final p = day.split('-').map(int.parse).toList();
    return DateTime(p[0], p[1], p[2]);
  }

  Future<String?> _pickDay(String day, {DateTime? first}) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _dayValue(day),
      firstDate: first ?? DateTime(now.year - 5),
      lastDate: DateTime(now.year + 20),
    );
    return picked == null ? null : Reminder.dayString(picked);
  }

  Future<void> _pickTime() async {
    final parts = _time.split(':').map(int.parse).toList();
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: parts[0], minute: parts[1]),
    );
    if (picked == null) return;
    setState(
      () => _time =
          '${picked.hour.toString().padLeft(2, '0')}:'
          '${picked.minute.toString().padLeft(2, '0')}',
    );
  }

  /// In words: "Goes off daily at 9:00, from 6 Oct until 12 Nov."
  String _summary(Reminder r) {
    final at = Reminder.formatTime(context, r.time);
    if (r.isPast()) return 'This has already gone off for the last time.';
    if (r.mode == ReminderMode.once) {
      final day = Reminder.formatDay(r.date);
      final when = const ['Today', 'Tomorrow', 'Yesterday'].contains(day)
          ? day.toLowerCase()
          : 'on $day';
      return 'Goes off $when at $at.';
    }
    final every = r.every.label.toLowerCase();
    final from = Reminder.formatDate(r.date);
    return r.mode == ReminderMode.repeat
        ? 'Goes off $every at $at, from $from until '
              '${Reminder.formatDate(r.until!)}.'
        : 'Goes off $every at $at from $from, until you turn it off.';
  }

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      text,
      style: Theme.of(context).textTheme.labelMedium?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final localizations = MaterialLocalizations.of(context);
    final reminder = _reminder;
    final quickPicks = [
      ('Today', _today),
      ('Tomorrow', Reminder.addDays(_today, 1)),
      ('Next week', Reminder.addDays(_today, 7)),
    ];
    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          20,
          0,
          20,
          16 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.initial == null ? 'Add reminder' : 'Reminder',
              style: textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _name,
              maxLength: Reminder.maxName,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Name (optional, shown in the notification)',
                hintText: 'e.g. Pay rent',
                floatingLabelBehavior: FloatingLabelBehavior.always,
                counterText: '',
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final (label, date) in quickPicks)
                  ChoiceChip(
                    label: Text(label),
                    selected: _date == date,
                    showCheckmark: false,
                    onSelected: (_) => setState(() => _date = date),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      final day = await _pickDay(_date);
                      if (day != null) setState(() => _date = day);
                    },
                    icon: const Icon(Icons.event_outlined, size: 18),
                    label: Text(
                      localizations.formatMediumDate(_dayValue(_date)),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _pickTime,
                    icon: const Icon(Icons.schedule, size: 18),
                    label: Text(Reminder.formatTime(context, _time)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            _label('Goes off'),
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<ReminderMode>(
                showSelectedIcon: false,
                segments: [
                  for (final m in ReminderMode.values)
                    ButtonSegment(value: m, label: Text(m.label)),
                ],
                selected: {_mode},
                onSelectionChanged: (s) => setState(() => _mode = s.first),
              ),
            ),
            if (_mode != ReminderMode.once) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<ReminderEvery>(
                      initialValue: _every,
                      decoration: const InputDecoration(
                        labelText: 'Repeats',
                        floatingLabelBehavior: FloatingLabelBehavior.always,
                      ),
                      items: [
                        for (final e in ReminderEvery.values)
                          DropdownMenuItem(value: e, child: Text(e.label)),
                      ],
                      onChanged: (e) => setState(() => _every = e ?? _every),
                    ),
                  ),
                  if (_mode == ReminderMode.repeat) ...[
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () async {
                          final day = await _pickDay(
                            reminder.until!,
                            first: _dayValue(_date),
                          );
                          if (day != null) setState(() => _until = day);
                        },
                        icon: const Icon(Icons.event_busy_outlined, size: 18),
                        label: Text(
                          'Until ${Reminder.formatDate(reminder.until!)}',
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ],
            const SizedBox(height: 10),
            Text(
              _summary(reminder),
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
                        Navigator.pop<ReminderEdit>(context, (reminder: null)),
                    style: TextButton.styleFrom(foregroundColor: scheme.error),
                    child: Text(
                      widget.initial!.mode == ReminderMode.permanent
                          ? 'Turn off'
                          : 'Remove',
                    ),
                  ),
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () => Navigator.pop<ReminderEdit>(context, (
                    reminder: reminder,
                  )),
                  child: const Text('Save'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// An item's reminder as a chip beside its tags: its name and next time,
/// with a repeat mark when it repeats. Red once it's over, accent when it
/// goes off today. Kept current as time passes. Opens the reminder sheet
/// when tappable.
class ReminderChip extends StatefulWidget {
  const ReminderChip({super.key, required this.reminder, this.onTap});

  final Reminder reminder;
  final VoidCallback? onTap;

  @override
  State<ReminderChip> createState() => _ReminderChipState();
}

class _ReminderChipState extends State<ReminderChip> {
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
    final reminder = widget.reminder;
    final now = DateTime.now();
    final past = reminder.isPast(now);
    final today =
        !past &&
        Reminder.dayString(reminder.current(now)) == Reminder.dayString(now);
    final color = past
        ? scheme.error
        : today
        ? scheme.primary
        : scheme.onSurfaceVariant;
    final when = reminder.label(context, now);
    final text = reminder.name.isEmpty ? when : '${reminder.name} · $when';
    final style = TextStyle(
      fontSize: 10,
      fontWeight: FontWeight.w500,
      color: color,
    );
    return Semantics(
      button: widget.onTap != null,
      label: [
        'Reminder${reminder.name.isEmpty ? '' : ' "${reminder.name}"'}'
            '${past ? ', over' : ''}: $when',
        if (reminder.repeats) reminder.describeRepeat(now),
      ].join(', '),
      excludeSemantics: true,
      child: InkWell(
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: past || today
                ? color.withValues(alpha: 0.12)
                : scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: past || today
                  ? color.withValues(alpha: 0.35)
                  : scheme.outlineVariant,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.notifications_none_rounded, size: 12, color: color),
              const SizedBox(width: 3),
              Flexible(
                child: Text(
                  text,
                  style: style,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (reminder.repeats) ...[
                const SizedBox(width: 3),
                Icon(Icons.repeat_rounded, size: 12, color: color),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
