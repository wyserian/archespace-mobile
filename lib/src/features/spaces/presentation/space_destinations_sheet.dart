import 'package:flutter/material.dart';

import 'package:archespace_mobile/src/features/spaces/data/space_repository.dart';
import 'package:archespace_mobile/src/features/spaces/domain/space.dart';
import 'package:archespace_mobile/src/features/spaces/domain/space_colors.dart';
import 'package:archespace_mobile/src/features/spaces/domain/space_paths.dart';
import 'package:archespace_mobile/src/features/spaces/domain/space_tree.dart';
import 'package:archespace_mobile/src/features/vault/application/vault_session.dart';
import 'package:archespace_mobile/src/shared/widgets/app_snackbar.dart';

/// Where something can be moved: a space, or the dashboard when [id] is null.
typedef MoveTarget = ({String? id, String name});

/// The spaces something can move into, in tree order with their depth: all
/// but [exclude] and read-only ones, which take nothing new.
List<(Space, int)> moveDestinations(List<Space> spaces, Set<String> exclude) =>
    spaceTreeOrder(
      spaces,
    ).where((e) => !exclude.contains(e.$1.id) && !e.$1.readOnly).toList();

/// Ask where to move to: the dashboard (when [dashboardSubtitle] is given),
/// then the spaces as a tree, each sub-space indented with its path as the
/// subtitle. Null when cancelled.
Future<MoveTarget?> showSpaceDestinations(
  BuildContext context, {
  required List<Space> spaces,
  required Set<String> exclude,
  String? dashboardSubtitle,
}) {
  final paths = spacePathLabels(spaces);
  final destinations = moveDestinations(spaces, exclude);
  return showModalBottomSheet<MoveTarget>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text(
              'Move to',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          if (dashboardSubtitle != null)
            ListTile(
              leading: const Icon(Icons.dashboard_outlined),
              title: const Text('Dashboard'),
              subtitle: Text(dashboardSubtitle),
              onTap: () =>
                  Navigator.pop(sheetContext, (id: null, name: 'Dashboard')),
            ),
          for (final (s, depth) in destinations)
            ListTile(
              contentPadding: EdgeInsets.only(
                left: 16 + (depth < 4 ? depth : 4) * 16.0,
                right: 16,
              ),
              // In the space's own colour, so spaces tell apart at a glance.
              leading: Icon(Icons.folder_outlined, color: spaceColor(s.color)),
              title: Text(s.name.isEmpty ? 'Untitled' : s.name),
              subtitle: depth > 0 && s.parentId != null
                  ? Text(
                      paths[s.parentId] ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    )
                  : null,
              onTap: () => Navigator.pop(sheetContext, (
                id: s.id,
                name: s.name.isEmpty ? 'Untitled' : s.name,
              )),
            ),
        ],
      ),
    ),
  );
}

/// Move spaces, with everything in them, into another space or out to the
/// dashboard. A space's own sub-spaces, and the place it already is, aren't
/// offered. True when they moved.
Future<bool> moveSpacesTo(BuildContext context, List<String> ids) async {
  final repo = SpaceRepository(VaultSession.instance.masterKey);
  List<Space> spaces;
  try {
    spaces = (await repo.listSpaces()).spaces;
  } catch (_) {
    if (context.mounted) showErrorSnack(context, "Couldn't load spaces.");
    return false;
  }
  final moving = spaces.where((s) => ids.contains(s.id)).toList();
  final parents = {for (final s in moving) s.parentId};
  final here = parents.length == 1 ? parents.single : null;
  final allTopLevel = parents.length == 1 && here == null;
  final exclude = {
    ...ids,
    ...descendantsOf(
      ids,
      spaces,
      idOf: (s) => s.id,
      parentOf: (s) => s.parentId,
    ),
    ?here,
  };
  if (!context.mounted) return false;
  if (allTopLevel && moveDestinations(spaces, exclude).isEmpty) {
    showErrorSnack(context, 'No space to move to.');
    return false;
  }
  final target = await showSpaceDestinations(
    context,
    spaces: spaces,
    exclude: exclude,
    dashboardSubtitle: allTopLevel ? null : 'Top level',
  );
  if (target == null) return false;
  try {
    await repo.moveSpaces(ids, target.id);
    if (context.mounted) showSuccessSnack(context, 'Moved to ${target.name}');
    return true;
  } catch (_) {
    if (context.mounted) showErrorSnack(context, "Couldn't move the space.");
    return false;
  }
}
