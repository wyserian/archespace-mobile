import 'package:flutter/material.dart';

import 'package:archespace_mobile/src/features/spaces/data/space_repository.dart';
import 'package:archespace_mobile/src/features/spaces/domain/space.dart';
import 'package:archespace_mobile/src/features/spaces/domain/space_colors.dart';
import 'package:archespace_mobile/src/features/vault/application/vault_session.dart';
import 'package:archespace_mobile/src/shared/util/errors.dart';
import 'package:archespace_mobile/src/shared/widgets/app_snackbar.dart';
import 'package:archespace_mobile/src/shared/widgets/confirm_dialog.dart';
import 'package:archespace_mobile/src/shared/widgets/tap_area.dart';

/// Create or edit a space (name, description, colour); tags are added and
/// removed on the space card. Pass [existing] to edit. Pops `true` on save so
/// the caller can refresh.
class SpaceEditorScreen extends StatefulWidget {
  const SpaceEditorScreen({super.key, this.existing, this.parentId});

  final Space? existing;

  /// When set, a newly created space becomes a sub-space of this parent.
  final String? parentId;

  @override
  State<SpaceEditorScreen> createState() => _SpaceEditorScreenState();
}

class _SpaceEditorScreenState extends State<SpaceEditorScreen> {
  late final TextEditingController _name = TextEditingController(
    text: widget.existing?.name ?? '',
  );
  late final TextEditingController _description = TextEditingController(
    text: widget.existing?.description ?? '',
  );

  late String? _color = widget.existing?.color;

  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      showErrorSnack(context, 'Enter a name for the space.');
      return;
    }
    setState(() => _saving = true);
    final repo = SpaceRepository(VaultSession.instance.masterKey);
    try {
      if (widget.existing != null) {
        await repo.updateSpace(
          id: widget.existing!.id,
          name: name,
          description: _description.text.trim(),
          color: _color,
        );
      } else {
        await repo.createSpace(
          name: name,
          description: _description.text.trim(),
          color: _color,
          parentId: widget.parentId,
        );
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        showErrorSnack(context, saveErrorMessage(e));
      }
    }
  }

  bool _isDirty() {
    final e = widget.existing;
    return _name.text.trim() != (e?.name ?? '').trim() ||
        _description.text.trim() != (e?.description ?? '').trim() ||
        _color != e?.color;
  }

  // Save on leave so edits aren't lost. If there's nothing to save, just close;
  // if a name is still missing (required), confirm before discarding.
  Future<void> _handleBack() async {
    if (_saving) return;
    if (!_isDirty()) {
      if (mounted) Navigator.pop(context, false);
      return;
    }
    if (_name.text.trim().isEmpty) {
      final discard = await confirmAction(
        context,
        title: 'Discard changes?',
        message: 'This space needs a name before it can be saved.',
        confirmLabel: 'Discard',
        destructive: true,
      );
      if (discard && mounted) Navigator.pop(context, false);
      return;
    }
    await _save(); // pops true on success; on failure shows the error and stays
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _handleBack();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.existing != null ? 'Edit space' : 'New space'),
          actions: [
            _saving
                ? const Padding(
                    padding: EdgeInsets.all(16),
                    child: SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : IconButton(
                    onPressed: _save,
                    icon: const Icon(Icons.check),
                    tooltip: 'Save',
                  ),
          ],
        ),
        body: SafeArea(
          top: false,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              TextField(
                controller: _name,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(labelText: 'Name'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _description,
                minLines: 2,
                maxLines: 5,
                decoration: const InputDecoration(
                  labelText: 'Description',
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 20),
              _label('Colour'),
              const SizedBox(height: 8),
              _colorPicker(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _label(String text) => Text(
    text,
    style: TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.6,
      color: Theme.of(context).colorScheme.primary,
    ),
  );

  Widget _colorPicker() {
    final scheme = Theme.of(context).colorScheme;
    Widget dot(String? id, Color? color) {
      final isSelected = _color == id;
      return Semantics(
        button: true,
        selected: isSelected,
        label: id == null ? 'No colour' : '$id colour',
        child: TapArea(
          onTap: () => setState(() => _color = id),
          child: Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color,
              border: Border.all(
                color: isSelected ? scheme.onSurface : scheme.outlineVariant,
                width: isSelected ? 3 : 1,
              ),
            ),
            child: color == null
                ? Icon(Icons.block, size: 18, color: scheme.outline)
                : (isSelected
                      ? const Icon(Icons.check, color: Colors.white, size: 20)
                      : null),
          ),
        ),
      );
    }

    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        dot(null, null),
        for (final entry in kSpaceColors.entries) dot(entry.key, entry.value),
      ],
    );
  }
}
