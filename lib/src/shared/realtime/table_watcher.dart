import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:archespace_mobile/src/shared/data/app_mode.dart';

/// Subscribes to Supabase postgres changes on [table] (optionally filtered by
/// [filterColumn] == [filterValue]) and calls [onChange], debounced to coalesce
/// bursts - e.g. a reorder that touches many rows, or the realtime echo of the
/// app's own writes. Mirrors the web hooks' 250ms coalescing.
class TableWatcher {
  TableWatcher({
    required String channelName,
    required String table,
    required this.onChange,
    String? filterColumn,
    String? filterValue,
    this.debounce = const Duration(milliseconds: 300),
  }) {
    // Local mode has no server to hear changes from; this device is the only
    // writer.
    if (AppMode.isLocal) return;
    _channel = Supabase.instance.client
        .channel(channelName)
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: table,
          filter: filterColumn == null
              ? null
              : PostgresChangeFilter(
                  type: PostgresChangeFilterType.eq,
                  column: filterColumn,
                  value: filterValue,
                ),
          callback: (_) => _schedule(),
        )
        .subscribe();
  }

  final void Function() onChange;
  final Duration debounce;
  RealtimeChannel? _channel;
  Timer? _timer;

  void _schedule() {
    _timer?.cancel();
    _timer = Timer(debounce, onChange);
  }

  void dispose() {
    _timer?.cancel();
    final channel = _channel;
    if (channel != null) Supabase.instance.client.removeChannel(channel);
  }
}
