import 'dart:async';

import 'package:openremotecode/features/server_settings/data/server_settings_repository.dart';

final class MemoryServerSettingsRepository implements ServerSettingsRepository {
  MemoryServerSettingsRepository({this.value});

  String? value;
  bool failRead = false;
  bool failWrite = false;
  int writes = 0;
  Completer<void>? pendingWrite;
  Completer<void>? pendingRead;

  @override
  Future<String?> readServer() async {
    if (pendingRead case final pending?) await pending.future;
    if (failRead) throw StateError('Storage unavailable');
    return value;
  }

  @override
  Future<void> writeServer(String server) async {
    writes++;
    if (pendingWrite case final pending?) await pending.future;
    if (failWrite) throw StateError('Storage unavailable');
    value = server;
  }
}
