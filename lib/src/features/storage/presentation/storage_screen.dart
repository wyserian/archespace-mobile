import 'package:flutter/material.dart';

import 'package:archespace_mobile/src/features/items/domain/item_types.dart';
import 'package:archespace_mobile/src/features/items/presentation/widgets/type_badge.dart';
import 'package:archespace_mobile/src/features/spaces/presentation/widgets/app_drawer.dart';
import 'package:archespace_mobile/src/features/storage/data/storage_repository.dart';
import 'package:archespace_mobile/src/features/vault/application/vault_session.dart';
import 'package:archespace_mobile/src/shared/widgets/app_snackbar.dart';
import 'package:archespace_mobile/src/shared/widgets/bulk_action_bar.dart';
import 'package:archespace_mobile/src/shared/widgets/select_box.dart';
import 'package:archespace_mobile/src/shared/widgets/scrollable_message.dart';

enum StorageMode { archive, bin }

/// Shared screen for the Archive and the Recycle bin. Lists archived / deleted
/// spaces and items with restore + delete actions.
class StorageScreen extends StatefulWidget {
  const StorageScreen({super.key, required this.mode});

  final StorageMode mode;

  @override
  State<StorageScreen> createState() => _StorageScreenState();
}

class _StorageScreenState extends State<StorageScreen> {
  final StorageRepository _repo = StorageRepository(
    VaultSession.instance.masterKey,
  );
  List<StoredEntry>? _entries;
  Object? _error;

  // Multi-select state. Selection is keyed by table+id so a space and an item
  // that happen to share an id can't collide.
  bool _selectMode = false;
  final Set<String> _selected = {};

  bool get _isBin => widget.mode == StorageMode.bin;

  String _key(StoredEntry e) => '${e.isSpace ? 'space' : 'item'}:${e.id}';

  List<StoredEntry> get _selectedEntries => (_entries ?? const <StoredEntry>[])
      .where((e) => _selected.contains(_key(e)))
      .toList();

  void _enterSelect([StoredEntry? first]) {
    setState(() {
      _selectMode = true;
      if (first != null) _selected.add(_key(first));
    });
  }

  void _exitSelect() {
    setState(() {
      _selectMode = false;
      _selected.clear();
    });
  }

  void _selectAll() => setState(() {
    _selected.addAll((_entries ?? const <StoredEntry>[]).map(_key));
  });

  void _toggle(StoredEntry e) {
    final k = _key(e);
    setState(() {
      if (!_selected.remove(k)) _selected.add(k);
    });
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final entries = _isBin
          ? await _repo.loadDeleted()
          : await _repo.loadArchived();
      if (mounted) {
        setState(() {
          _entries = entries;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _restore(StoredEntry e) async {
    try {
      if (_isBin) {
        await _repo.restoreDeleted(e);
      } else {
        await _repo.restoreArchived(e);
      }
      if (mounted) _load();
    } catch (_) {
      _snack("Couldn't restore it.");
    }
  }

  Future<void> _delete(StoredEntry e) async {
    if (_isBin) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Delete permanently?'),
          content: Text(
            '"${e.label.isEmpty ? 'Untitled' : e.label}" '
            'will be permanently deleted. This cannot be undone.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Delete forever'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    try {
      if (_isBin) {
        await _repo.purge(e);
      } else {
        await _repo.moveToBin(e);
      }
      if (mounted) _load();
    } catch (_) {
      _snack("Couldn't delete it.");
    }
  }

  Future<bool> _confirm(
    String title,
    String message,
    String confirmLabel,
  ) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    return result == true;
  }

  Future<void> _restoreSelected() async {
    final selected = _selectedEntries;
    if (selected.isEmpty) return;
    try {
      if (_isBin) {
        await _repo.restoreDeletedMany(selected);
      } else {
        await _repo.restoreArchivedMany(selected);
      }
      _exitSelect();
      if (mounted) _load();
    } catch (_) {
      _snack("Couldn't restore them.");
    }
  }

  Future<void> _deleteSelected() async {
    final selected = _selectedEntries;
    if (selected.isEmpty) return;
    final n = selected.length;
    if (_isBin) {
      final ok = await _confirm(
        'Delete permanently?',
        '$n ${n == 1 ? 'entry' : 'entries'} will be permanently deleted. '
            'This cannot be undone.',
        'Delete forever',
      );
      if (!ok) return;
    }
    try {
      if (_isBin) {
        await _repo.purgeMany(selected);
      } else {
        await _repo.moveManyToBin(selected);
      }
      _exitSelect();
      if (mounted) _load();
    } catch (_) {
      _snack("Couldn't delete them.");
    }
  }

  Future<void> _emptyBin() async {
    final ok = await _confirm(
      'Empty recycle bin?',
      'Everything in the recycle bin will be permanently deleted. '
          'This cannot be undone.',
      'Empty bin',
    );
    if (!ok) return;
    try {
      await _repo.purgeAll();
      _exitSelect();
      if (mounted) _load();
    } catch (_) {
      _snack("Couldn't empty the recycle bin.");
    }
  }

  void _snack(String message) {
    if (mounted) showErrorSnack(context, message);
  }

  @override
  Widget build(BuildContext context) {
    final hasEntries = _entries?.isNotEmpty ?? false;
    return Scaffold(
      drawer: _selectMode
          ? null
          : AppDrawer(current: _isBin ? DrawerPage.bin : DrawerPage.archive),
      drawerEdgeDragWidth: AppDrawer.edgeDragWidth(context),
      appBar: _selectMode
          ? AppBar(
              leading: IconButton(
                icon: const Icon(Icons.close),
                onPressed: _exitSelect,
                tooltip: 'Cancel',
              ),
              title: Text('${_selected.length} selected'),
              actions: [
                IconButton(
                  onPressed: _selectAll,
                  icon: const Icon(Icons.select_all),
                  tooltip: 'Select all',
                ),
              ],
            )
          : AppBar(
              // Keep Back; the drawer opens with a slide from the left.
              leading: const BackButton(),
              title: Text(_isBin ? 'Recycle bin' : 'Archive'),
              actions: [
                if (hasEntries)
                  IconButton(
                    onPressed: _enterSelect,
                    icon: const Icon(Icons.checklist),
                    tooltip: 'Select',
                  ),
                if (_isBin && hasEntries)
                  IconButton(
                    onPressed: _emptyBin,
                    icon: const Icon(Icons.delete_sweep_outlined),
                    tooltip: 'Empty recycle bin',
                  ),
              ],
            ),
      // The batch actions, in the same bar as the other screens.
      bottomNavigationBar: _selectMode
          ? BulkActionBar(
              count: _selected.length,
              onClear: _exitSelect,
              actions: [
                BulkAction(
                  icon: Icons.restore,
                  label: 'Restore',
                  onPressed: _restoreSelected,
                ),
                BulkAction(
                  icon: _isBin ? Icons.delete_forever : Icons.delete_outline,
                  label: _isBin ? 'Delete permanently' : 'Move to bin',
                  onPressed: _deleteSelected,
                  destructive: true,
                ),
              ],
            )
          : null,
      body: _entries == null && _error == null
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(top: false, child: _body()),
    );
  }

  Widget _body() {
    if (_entries == null && _error != null) {
      return StateMessage(
        icon: Icons.cloud_off_outlined,
        title: "Couldn't load",
        message: 'Something went wrong. Check your connection and try again.',
        actionLabel: 'Retry',
        actionIcon: Icons.refresh,
        onAction: _load,
        destructiveIcon: true,
      );
    }
    final entries = _entries ?? const <StoredEntry>[];
    if (entries.isEmpty) {
      return StateMessage(
        icon: _isBin ? Icons.delete_outline : Icons.archive_outlined,
        title: _isBin ? 'Recycle bin is empty' : 'Nothing archived yet',
        message: _isBin
            ? 'Spaces and items you delete stay here until you delete them '
                  'for good.'
            : 'Archive a space or item to tuck it away without deleting it.',
      );
    }
    final spaces = entries.where((e) => e.isSpace).toList();
    final items = entries.where((e) => !e.isSpace).toList();
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          if (spaces.isNotEmpty) const _Header('Spaces'),
          for (final e in spaces) _tile(e),
          if (items.isNotEmpty) const _Header('Items'),
          for (final e in items) _tile(e),
        ],
      ),
    );
  }

  Widget _tile(StoredEntry e) {
    // An item shows its coloured type badge, as on item cards.
    final Widget icon = e.isSpace || itemTypeDef(e.type) == null
        ? Icon(e.isSpace ? Icons.folder_outlined : Icons.notes)
        : TypeBadge(type: e.type);
    final title = Text(e.label.isEmpty ? 'Untitled' : e.label);

    if (_selectMode) {
      final selected = _selected.contains(_key(e));
      // The same check box as space and item cards, with no recolouring.
      return ListTile(
        leading: icon,
        title: title,
        trailing: SelectBox(selected: selected),
        onTap: () => _toggle(e),
      );
    }

    return ListTile(
      leading: icon,
      title: title,
      onLongPress: () => _enterSelect(e),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            onPressed: () => _restore(e),
            icon: const Icon(Icons.restore),
            tooltip: 'Restore',
          ),
          IconButton(
            onPressed: () => _delete(e),
            icon: Icon(_isBin ? Icons.delete_forever : Icons.delete_outline),
            tooltip: _isBin ? 'Delete permanently' : 'Move to bin',
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.6,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}
