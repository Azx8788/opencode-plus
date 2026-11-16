import 'dart:async';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class MemoryTestSecure extends FlutterSecureStorage {
  final values = <String, String>{};
  bool failRead = false, failWrite = false;
  Completer<void>? holdWrite;
  int reads = 0, writes = 0;
  @override
  Future<String?> read({required String key, AppleOptions? iOptions,
    AndroidOptions? aOptions, LinuxOptions? lOptions, WebOptions? webOptions,
    AppleOptions? mOptions, WindowsOptions? wOptions}) async {
    reads++;
    if (failRead) throw StateError('Fixture read failure');
    return values[key];
  }
  @override
  Future<void> write({required String key, required String? value, AppleOptions? iOptions,
    AndroidOptions? aOptions, LinuxOptions? lOptions, WebOptions? webOptions,
    AppleOptions? mOptions, WindowsOptions? wOptions}) async {
    writes++;
    if (holdWrite != null) await holdWrite!.future;
    if (failWrite) throw StateError('Fixture write failure');
    if (value == null) { values.remove(key); } else { values[key] = value; }
  }
}
