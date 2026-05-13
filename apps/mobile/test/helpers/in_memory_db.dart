import 'package:drift/native.dart';

import 'package:kp_mobile/data/drift/database.dart';

KpDatabase buildInMemoryDatabase() {
  return KpDatabase.test(NativeDatabase.memory());
}
