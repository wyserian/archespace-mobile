import 'dart:typed_data';

import 'package:archespace_mobile/src/features/items/domain/space_item.dart';
import 'package:archespace_mobile/src/features/spaces/domain/space.dart';
import 'package:archespace_mobile/src/features/vault/application/content_lock.dart';
import 'package:archespace_mobile/src/features/vault/application/vault_session.dart';
import 'package:flutter_test/flutter_test.dart';

SpaceItem _item(String id, {bool locked = false, String? spaceId}) => SpaceItem(
  id: id,
  type: 'textbox',
  title: id,
  content: const {'text': 'secret'},
  pinned: false,
  locked: locked,
  spaceId: spaceId,
);

Space _space(String id, {bool locked = false, String? parentId}) => Space(
  id: id,
  name: id,
  description: '',
  pinned: false,
  locked: locked,
  parentId: parentId,
);

void main() {
  final lock = ContentLock.instance;
  setUp(lock.hideAll);

  test('a locked item is hidden until opened, and again after', () {
    final item = _item('a', locked: true);
    expect(lock.isItemHidden(item), isTrue);
    lock.revealItem(item);
    expect(lock.isItemHidden(item), isFalse);
    lock.hide('a');
    expect(lock.isItemHidden(item), isTrue);
    expect(lock.isItemHidden(_item('b')), isFalse);
  });

  test('a locked space hides its sub-spaces and their items', () {
    lock.setSpaces([
      _space('top', locked: true),
      _space('sub', parentId: 'top'),
      _space('open'),
    ]);
    final inSub = _item('x', spaceId: 'sub');
    expect(lock.isSpaceHidden('sub'), isTrue);
    expect(lock.isItemHidden(inSub), isTrue);
    expect(lock.isItemHidden(_item('y', spaceId: 'open')), isFalse);

    // Opening the item opens the protected space above it.
    lock.revealItem(inSub);
    expect(lock.isSpaceHidden('sub'), isFalse);
    expect(lock.isRevealed('top'), isTrue);
  });

  test('a locked space hides spaces nested deep under it', () {
    lock.setSpaces([
      for (var i = 0; i < 8; i++)
        _space(
          'd$i',
          locked: i == 0 || i == 5,
          parentId: i == 0 ? null : 'd${i - 1}',
        ),
    ]);
    final deep = _item('z', spaceId: 'd7');
    expect(lock.isSpaceHidden('d7'), isTrue);
    expect(lock.isItemHidden(deep), isTrue);

    // Opening the deepest space opens every protected space above it.
    lock.revealSpace('d7');
    expect(lock.isRevealed('d0'), isTrue);
    expect(lock.isRevealed('d5'), isTrue);
    expect(lock.isItemHidden(deep), isFalse);
  });

  test('a parent loop does not hang', () {
    lock.setSpaces([
      _space('loop-a', parentId: 'loop-b'),
      _space('loop-b', parentId: 'loop-a'),
    ]);
    expect(lock.isSpaceHidden('loop-a'), isFalse);
  });

  test('locking a space hides it at once; the vault locking hides all', () {
    lock.setSpaces([_space('s')]);
    lock.setSpaceLocked('s', true);
    expect(lock.isSpaceHidden('s'), isTrue);
    lock.revealSpace('s');
    expect(lock.isSpaceHidden('s'), isFalse);

    VaultSession.instance.unlock(Uint8List(32));
    VaultSession.instance.lock();
    expect(lock.isSpaceHidden('s'), isTrue);
  });
}
