import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:archespace_mobile/src/shared/data/app_mode.dart';
import 'package:archespace_mobile/src/shared/data/offline_db.dart';

/// Hears Supabase postgres changes on [table] (optionally filtered by
/// [filterColumn] == [filterValue]) and brings the offline copy up to date;
/// calls [onChange] whenever a sync changed the copy. Debounced to coalesce
/// bursts - e.g. a reorder that touches many rows, or the realtime echo of the
/// app's own writes.
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
    OfflineDb.instance.changes.addListener(onChange);
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
    _timer = Timer(debounce, OfflineDb.instance.sync);
  }

  void dispose() {
    _timer?.cancel();
    final channel = _channel;
    if (channel == null) return;
    OfflineDb.instance.changes.removeListener(onChange);
    Supabase.instance.client.removeChannel(channel);
  }
}
