import 'package:flutter_test/flutter_test.dart';

import 'package:archespace_mobile/src/shared/data/app_mode.dart';
import 'package:archespace_mobile/src/shared/data/audit_log.dart';

void main() {
  test('logging never throws, with no server or in local mode', () async {
    // No Supabase here: the call fails inside and is swallowed.
    await expectLater(logAudit('login'), completes);
    AppMode.local.value = true;
    addTearDown(() => AppMode.local.value = false);
    await expectLater(logAudit('login'), completes);
  });
}
