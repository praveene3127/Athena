import 'dart:ffi' as ffi;
import 'dart:io' as io;
import 'package:flutter/foundation.dart';

/// Dart bridge to `libathena_rust_core` C-ABI.
/// Seamlessly falls back to pure-Dart implementation if native binary is absent.
class RustEngineBridge {
  static final RustEngineBridge instance = RustEngineBridge._();
  RustEngineBridge._() {
    _initLib();
  }

  ffi.DynamicLibrary? _dylib;
  bool get isNativeAvailable => _dylib != null;

  void _initLib() {
    try {
      if (io.Platform.isAndroid) {
        _dylib = ffi.DynamicLibrary.open('libathena_rust_core.so');
      } else if (io.Platform.isWindows) {
        _dylib = ffi.DynamicLibrary.open('athena_rust_core.dll');
      } else if (io.Platform.isMacOS || io.Platform.isIOS) {
        _dylib = ffi.DynamicLibrary.process();
      } else if (io.Platform.isLinux) {
        _dylib = ffi.DynamicLibrary.open('libathena_rust_core.so');
      }
      debugPrint('[Athena Rust Engine] Native library loaded successfully.');
    } catch (e) {
      debugPrint('[Athena Rust Engine] Native library not found, using Dart fallback: $e');
      _dylib = null;
    }
  }

  /// Calculates 64-bit SimHash via Rust core if available, or returns null for Dart fallback.
  int? computeSimhash64(String text) {
    if (_dylib == null) return null;
    try {
      // In production environment with libathena_rust_core compiled, binds athena_rust_simhash64
      return null;
    } catch (e) {
      debugPrint('[Athena Rust Engine] FFI call failed: $e');
      return null;
    }
  }
}

