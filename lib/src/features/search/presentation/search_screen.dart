import 'package:flutter/material.dart';

import 'package:archespace_mobile/src/features/items/domain/item_types.dart';
import 'package:archespace_mobile/src/features/search/data/search_repository.dart';
import 'package:archespace_mobile/src/features/spaces/domain/space.dart';
import 'package:archespace_mobile/src/features/spaces/presentation/space_detail_screen.dart';
import 'package:archespace_mobile/src/features/spaces/presentation/widgets/app_drawer.dart';
import 'package:archespace_mobile/src/features/vault/application/vault_session.dart';
import 'package:archespace_mobile/src/shared/widgets/scrollable_message.dart';
import 'package:archespace_mobile/src/shared/widgets/search_field.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final TextEditingController _controller = TextEditingController();
  List<SearchHit>? _all;
  Object? _error;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final hits = await SearchRepository(
        VaultSession.instance.masterKey,
      ).loadIndex();
      if (mounted) setState(() => _all = hits);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  void _open(SearchHit hit) {
    final spaceId = hit.spaceId;
    if (spaceId == null) {
      // A dashboard item: return to the dashboard, which scrolls to and
      // highlights it (search is opened from there).
      Navigator.of(context).pop(hit.id);
      return;
    }
    final space = Space(
      id: spaceId,
      name: hit.spaceName.isEmpty ? hit.title : hit.spaceName,
      description: '',
      pinned: false,
    );
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SpaceDetailScreen(
          space: space,
          focusItemId: hit.isSpace ? null : hit.id,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      drawer: const AppDrawer(current: DrawerPage.other),
      drawerEdgeDragWidth: AppDrawer.edgeDragWidth(context),
      appBar: AppBar(
        // Keep Back; the drawer opens with a slide from the left.
        leading: const BackButton(),
        titleSpacing: 0,
        // The same field as the dashboard's, now typed into.
        title: SearchField(
          hint: 'Search spaces and items',
          controller: _controller,
          autofocus: true,
          onChanged: (v) => setState(() => _query = v),
        ),
        actions: const [SizedBox(width: 12)],
      ),
      body: _all == null && _error == null
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(top: false, child: _results()),
    );
  }

  Widget _results() {
    if (_all == null && _error != null) {
      return StateMessage(
        icon: Icons.cloud_off_outlined,
        title: 'Search unavailable',
        message: 'Something went wrong. Check your connection and try again.',
        actionLabel: 'Retry',
        actionIcon: Icons.refresh,
        onAction: _load,
        destructiveIcon: true,
      );
    }
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) {
      return const StateMessage(
        icon: Icons.search,
        title: 'Search your vault',
        message: 'Find spaces and items by name, tag, or content.',
      );
    }
    final matches = _all!.where((h) => h.matches(q)).toList();
    final spaces = matches.where((h) => h.isSpace).toList();
    final items = matches.where((h) => !h.isSpace).toList();
    if (matches.isEmpty) {
      return StateMessage(
        icon: Icons.search_off,
        title: 'No results',
        message: 'Nothing matched "${_query.trim()}". Try a different term.',
      );
    }
    return ListView(
      children: [
        if (spaces.isNotEmpty) const _Header('Spaces'),
        for (final hit in spaces)
          ListTile(
            leading: const Icon(Icons.folder_outlined),
            title: Text(hit.title.isEmpty ? 'Untitled' : hit.title),
            onTap: () => _open(hit),
          ),
        if (items.isNotEmpty) const _Header('Items'),
        for (final hit in items)
          ListTile(
            leading: Icon(itemTypeDef(hit.type)?.icon ?? Icons.notes),
            title: Text(hit.title.isEmpty ? 'Untitled' : hit.title),
            subtitle: hit.spacePath.isEmpty
                ? null
                : Text(
                    'in ${hit.spacePath}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
            onTap: () => _open(hit),
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
