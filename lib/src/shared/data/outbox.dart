import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Changes made to this device's offline copy that the server hasn't had yet,
/// in the order they were made (see OfflineDb). Each holds only what the
/// server would store: ciphertext and plain metadata. It also remembers
/// whether the copy has been filled from the server once.
abstract class Outbox {
  /// Every change waiting, oldest first; each has its `seq`.
  Future<List<Map<String, dynamic>>> all();
  Future<void> add(Map<String, dynamic> op);

  /// Replace the change with the same `seq`.
  Future<void> put(Map<String, dynamic> op);
  Future<void> remove(int seq);

  Future<bool> filled();
  Future<void> setFilled(bool filled);
}

/// An outbox kept in this app's private storage, one file per account.
class FileOutbox implements Outbox {
  FileOutbox(this.userId);

  final String userId;

  // `{seq, filled, ops}`, read and written whole, one change at a time.
  Map<String, dynamic>? _state;
  Future<void> _last = Future.value();

  Future<File> _file() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/offline');
    if (!await dir.exists()) await dir.create(recursive: true);
    return File('${dir.path}/outbox_$userId.json');
  }

  Future<Map<String, dynamic>> _read() async {
    if (_state case final state?) return state;
    try {
      final file = await _file();
      if (await file.exists()) {
        return _state = (jsonDecode(await file.readAsString()) as Map)
            .cast<String, dynamic>();
      }
    } catch (_) {}
    return _state = {'seq': 0, 'filled': false, 'ops': <dynamic>[]};
  }

  Future<T> _change<T>(T Function(Map<String, dynamic> state) change) {
    final run = _last.then((_) async {
      final state = await _read();
      final result = change(state);
      final file = await _file();
      final temp = File('${file.path}.tmp');
      await temp.writeAsString(jsonEncode(state), flush: true);
      await temp.rename(file.path);
      return result;
    });
    _last = run.then((_) {}, onError: (_) {});
    return run;
  }

  List<Map<String, dynamic>> _ops(Map<String, dynamic> state) =>
      (state['ops'] as List).cast<Map<String, dynamic>>();

  @override
  Future<List<Map<String, dynamic>>> all() async {
    await _last;
    return [..._ops(await _read())];
  }

  @override
  Future<void> add(Map<String, dynamic> op) => _change((state) {
    final seq = (state['seq'] as int) + 1;
    state['seq'] = seq;
    state['ops'] = [
      ..._ops(state),
      {...op, 'seq': seq},
    ];
  });

  @override
  Future<void> put(Map<String, dynamic> op) => _change((state) {
    state['ops'] = [
      for (final o in _ops(state)) o['seq'] == op['seq'] ? op : o,
    ];
  });

  @override
  Future<void> remove(int seq) => _change((state) {
    state['ops'] = [
      for (final o in _ops(state))
        if (o['seq'] != seq) o,
    ];
  });

  @override
  Future<bool> filled() async => (await _read())['filled'] == true;

  @override
  Future<void> setFilled(bool filled) =>
      _change((state) => state['filled'] = filled);
}

/// An outbox in memory (tests).
class MemoryOutbox implements Outbox {
  final List<Map<String, dynamic>> _ops = [];
  var _seq = 0;
  var _filled = false;

  static Map<String, dynamic> _copy(Map<String, dynamic> op) =>
      (jsonDecode(jsonEncode(op)) as Map).cast<String, dynamic>();

  @override
  Future<List<Map<String, dynamic>>> all() async => [
    for (final op in _ops) _copy(op),
  ];

  @override
  Future<void> add(Map<String, dynamic> op) async =>
      _ops.add(_copy({...op, 'seq': ++_seq}));

  @override
  Future<void> put(Map<String, dynamic> op) async {
    final i = _ops.indexWhere((o) => o['seq'] == op['seq']);
    if (i >= 0) _ops[i] = _copy(op);
  }

  @override
  Future<void> remove(int seq) async =>
      _ops.removeWhere((o) => o['seq'] == seq);

  @override
  Future<bool> filled() async => _filled;

  @override
  Future<void> setFilled(bool filled) async => _filled = filled;
}
