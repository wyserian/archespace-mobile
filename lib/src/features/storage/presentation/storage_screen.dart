import 'package:flutter/material.dart';

import 'package:archespace_mobile/src/features/items/presentation/item_card.dart';
import 'package:archespace_mobile/src/features/spaces/presentation/widgets/app_drawer.dart';
import 'package:archespace_mobile/src/features/spaces/presentation/widgets/space_card.dart';
import 'package:archespace_mobile/src/features/storage/data/storage_repository.dart';
import 'package:archespace_mobile/src/features/vault/application/vault_session.dart';
import 'package:archespace_mobile/src/shared/widgets/app_snackbar.dart';
import 'package:archespace_mobile/src/shared/widgets/bulk_action_bar.dart';
import 'package:archespace_mobile/src/shared/widgets/confirm_dialog.dart';
import 'package:archespace_mobile/src/shared/widgets/scrollable_message.dart';

enum StorageMode { archive, bin }

/// Shared screen for the Archive and the Bin: archived / deleted spaces and
/// items as their read-only cards, each with its date under the name and two
/// buttons (Unarchive or Restore, and Delete), as on the web.
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
      if (mounted) {
        _load();
        showSuccessSnack(context, 'Restored');
      }
    } catch (_) {
      _snack("Couldn't restore it.");
    }
  }

  Future<void> _delete(StoredEntry e) async {
    final name = '"${e.label.isEmpty ? 'Untitled' : e.label}"';
    // Asks first in both: the bin's is for good, the archive's like any
    // other move to the bin.
    final ok = _isBin
        ? await _confirm(
            'Delete permanently?',
            '$name will be permanently deleted. This cannot be undone.',
            'Delete forever',
          )
        : await _confirm(
            'Move to bin?',
            '$name will be moved to the bin.',
            'Move to bin',
          );
    if (!ok) return;
    try {
      if (_isBin) {
        await _repo.purge(e);
      } else {
        await _repo.moveToBin(e);
      }
      if (mounted) {
        _load();
        // Say where it went; the bin can restore it.
        if (!_isBin) showSuccessSnack(context, 'Moved to the bin');
      }
    } catch (_) {
      _snack("Couldn't delete it.");
    }
  }

  /// Confirm a delete (to the bin, or for good), with the red button.
  Future<bool> _confirm(String title, String message, String confirmLabel) =>
      confirmAction(
        context,
        title: title,
        message: message,
        confirmLabel: confirmLabel,
        destructive: true,
      );

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
      if (mounted) {
        _load();
        final n = selected.length;
        showSuccessSnack(
          context,
          'Restored $n ${n == 1 ? 'entry' : 'entries'}',
        );
      }
    } catch (_) {
      _snack("Couldn't restore them.");
    }
  }

  Future<void> _deleteSelected() async {
    final selected = _selectedEntries;
    if (selected.isEmpty) return;
    final n = selected.length;
    final label = '$n ${n == 1 ? 'entry' : 'entries'}';
    final ok = _isBin
        ? await _confirm(
            'Delete permanently?',
            '$label will be permanently deleted. This cannot be undone.',
            'Delete forever',
          )
        : await _confirm(
            'Move $label to bin?',
            'They go to the bin.',
            'Move to bin',
          );
    if (!ok) return;
    try {
      if (_isBin) {
        await _repo.purgeMany(selected);
      } else {
        await _repo.moveManyToBin(selected);
      }
      _exitSelect();
      if (mounted) {
        _load();
        if (!_isBin) showSuccessSnack(context, 'Moved to the bin');
      }
    } catch (_) {
      _snack("Couldn't delete them.");
    }
  }

  Future<void> _emptyBin() async {
    final ok = await _confirm(
      'Empty the bin?',
      'Everything in the bin will be permanently deleted. '
          'This cannot be undone.',
      'Empty bin',
    );
    if (!ok) return;
    try {
      await _repo.purgeAll();
      _exitSelect();
      if (mounted) _load();
    } catch (_) {
      _snack("Couldn't empty the bin.");
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
              title: Text(_isBin ? 'Bin' : 'Archive'),
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
                    tooltip: 'Empty the bin',
                  ),
              ],
            ),
      // The batch actions, in the same bar as the other screens.
      bottomNavigationBar: _selectMode
          ? BulkActionBar(
              count: _selected.length,
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
        title: _isBin ? 'The bin is empty' : 'Nothing archived yet',
        message: _isBin
            ? 'Spaces and items you delete stay here until you delete them '
                  'for good.'
            : 'Archive a space or item to tuck it away without deleting it.',
      );
    }
    final spaces = entries.where((e) => e.isSpace).toList();
    final items = entries.where((e) => !e.isSpace).toList();
    // The spaces and items as their usual cards, read-only: nothing opens or
    // changes, and each card's only actions are its two buttons.
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: 16),
        children: [
          if (spaces.isNotEmpty) const _Header('Spaces'),
          for (final e in spaces)
            SpaceCard(
              key: ValueKey(_key(e)),
              space: e.space!,
              actions: _buttons(e),
              note: _note(e),
              selectMode: _selectMode,
              selected: _selected.contains(_key(e)),
              onSelectToggle: () => _toggle(e),
              // Unused: the buttons replace the card's menu.
              onTap: _none,
              onTogglePin: _none,
              onEdit: _none,
              onDuplicate: _none,
              onArchive: _none,
              onDelete: _none,
            ),
          if (items.isNotEmpty) const _Header('Items'),
          for (final e in items)
            ItemCard(
              key: ValueKey(_key(e)),
              item: e.item!,
              actions: _buttons(e),
              note: _note(e),
              selectMode: _selectMode,
              selected: _selected.contains(_key(e)),
              onSelectToggle: () => _toggle(e),
            ),
        ],
      ),
    );
  }

  static void _none() {}

  /// When it was archived or deleted: "Archived Today", "Deleted 3 days ago".
  String? _note(StoredEntry e) {
    final at = e.at;
    if (at == null) return null;
    final days = DateTime.now().difference(at.toLocal()).inDays;
    final when = days <= 0
        ? 'Today'
        : days == 1
        ? 'Yesterday'
        : '$days days ago';
    return '${_isBin ? 'Deleted' : 'Archived'} $when';
  }

  /// A card's two buttons: Unarchive / Restore, and Delete (to the bin, or
  /// for good in the bin, in red).
  Widget _buttons(StoredEntry e) {
    final error = Theme.of(context).colorScheme.error;
    const compact = VisualDensity.compact;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextButton.icon(
          onPressed: () => _restore(e),
          icon: const Icon(Icons.restore, size: 18),
          label: Text(_isBin ? 'Restore' : 'Unarchive'),
          style: TextButton.styleFrom(visualDensity: compact),
        ),
        TextButton.icon(
          onPressed: () => _delete(e),
          icon: Icon(
            _isBin ? Icons.delete_forever : Icons.delete_outline,
            size: 18,
          ),
          label: const Text('Delete'),
          style: TextButton.styleFrom(
            visualDensity: compact,
            foregroundColor: error,
          ),
        ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      // The same section label as Starred.
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(
        title,
        style: Theme.of(
          context,
        ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      ),
    );
  }
}
