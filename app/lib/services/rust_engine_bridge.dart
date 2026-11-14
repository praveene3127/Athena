import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io' as io;
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

// Struct returned by athena_rust_plan_chunks_utf8
final class FfiChunkResult extends ffi.Struct {
  @ffi.Uint32()
  external int chunkCount;

  external ffi.Pointer<Utf8> jsonPayload;

  @ffi.Int32()
  external int statusCode;
}

// Native function typedefs
typedef _SimhashNative = ffi.Uint64 Function(ffi.Pointer<Utf8>);
typedef _SimhashDart = int Function(ffi.Pointer<Utf8>);

typedef _FreeStringNative = ffi.Void Function(ffi.Pointer<Utf8>);
typedef _FreeStringDart = void Function(ffi.Pointer<Utf8>);

typedef _PlanChunksNative = FfiChunkResult Function(
  ffi.Pointer<Utf8> text,
  ffi.Size startPage,
  ffi.Size endPage,
  ffi.Size startSequence,
  ffi.Size startOffset,
  ffi.Bool isLastWindow,
  ffi.Size targetLen,
  ffi.Size maxLen,
);
typedef _PlanChunksDart = FfiChunkResult Function(
  ffi.Pointer<Utf8> text,
  int startPage,
  int endPage,
  int startSequence,
  int startOffset,
  bool isLastWindow,
  int targetLen,
  int maxLen,
);

typedef _IngestEpubNative = ffi.Pointer<Utf8> Function(
  ffi.Pointer<Utf8> path,
  ffi.Size startSpine,
  ffi.Size count,
);
typedef _IngestEpubDart = ffi.Pointer<Utf8> Function(
  ffi.Pointer<Utf8> path,
  int startSpine,
  int count,
);

typedef _CommitWindowNative = ffi.Pointer<Utf8> Function(
  ffi.Pointer<Utf8> dbPath,
  ffi.Pointer<Utf8> docId,
  ffi.Size windowPageStart,
  ffi.Size windowPageEnd,
  ffi.Pointer<Utf8> chunksJson,
  ffi.Pointer<Utf8> carryOver,
  ffi.Pointer<Utf8> prevChainHash,
  ffi.Pointer<Utf8> status,
);
typedef _CommitWindowDart = ffi.Pointer<Utf8> Function(
  ffi.Pointer<Utf8> dbPath,
  ffi.Pointer<Utf8> docId,
  int windowPageStart,
  int windowPageEnd,
  ffi.Pointer<Utf8> chunksJson,
  ffi.Pointer<Utf8> carryOver,
  ffi.Pointer<Utf8> prevChainHash,
  ffi.Pointer<Utf8> status,
);

/// Dart bridge to `libathena_rust_core` C-ABI.
/// Seamlessly falls back to pure-Dart implementation if native binary is absent.
class RustEngineBridge {
  static final RustEngineBridge instance = RustEngineBridge._();
  RustEngineBridge._() {
    _initLib();
  }

  /// Visible for testing: inject custom DynamicLibrary or test instance.
  RustEngineBridge.forTesting(ffi.DynamicLibrary dylib) {
    _dylib = dylib;
    _bindSymbols();
  }

  ffi.DynamicLibrary? _dylib;
  bool get isNativeAvailable => _dylib != null;

  _SimhashDart? _simhashFn;
  _PlanChunksDart? _planChunksFn;
  _IngestEpubDart? _ingestEpubFn;
  _CommitWindowDart? _commitWindowFn;
  _FreeStringDart? _freeStringFn;

  void _initLib() {
    try {
      if (kIsWeb) return;
      if (io.Platform.isAndroid) {
        _dylib = ffi.DynamicLibrary.open('libathena_rust_core.so');
      } else if (io.Platform.isWindows) {
        _dylib = ffi.DynamicLibrary.open('athena_rust_core.dll');
      } else if (io.Platform.isMacOS || io.Platform.isIOS) {
        _dylib = ffi.DynamicLibrary.process();
      } else if (io.Platform.isLinux) {
        _dylib = ffi.DynamicLibrary.open('libathena_rust_core.so');
      }
      _bindSymbols();
      debugPrint('[Athena Rust Engine] Native library loaded and bound successfully.');
    } catch (e) {
      debugPrint('[Athena Rust Engine] Native library not found, using Dart fallback: $e');
      _dylib = null;
    }
  }

  void _bindSymbols() {
    final lib = _dylib;
    if (lib == null) return;
    try {
      _simhashFn = lib.lookupFunction<_SimhashNative, _SimhashDart>('athena_rust_simhash64');
    } catch (e) {
      debugPrint('[Athena Rust Engine] symbol athena_rust_simhash64 not found: $e');
    }

    try {
      _freeStringFn = lib.lookupFunction<_FreeStringNative, _FreeStringDart>('athena_rust_free_string');
    } catch (e) {
      debugPrint('[Athena Rust Engine] symbol athena_rust_free_string not found: $e');
    }

    try {
      _planChunksFn = lib.lookupFunction<_PlanChunksNative, _PlanChunksDart>('athena_rust_plan_chunks_utf8');
    } catch (e) {
      debugPrint('[Athena Rust Engine] symbol athena_rust_plan_chunks_utf8 not found: $e');
    }

    try {
      _ingestEpubFn = lib.lookupFunction<_IngestEpubNative, _IngestEpubDart>('athena_rust_ingest_epub_windowed');
    } catch (e) {
      debugPrint('[Athena Rust Engine] symbol athena_rust_ingest_epub_windowed not found: $e');
    }

    try {
      _commitWindowFn = lib.lookupFunction<_CommitWindowNative, _CommitWindowDart>('athena_rust_commit_window_batch');
    } catch (e) {
      debugPrint('[Athena Rust Engine] symbol athena_rust_commit_window_batch not found: $e');
    }
  }

  /// Calculates 64-bit SimHash via Rust core if available, or returns null for Dart fallback.
  int? computeSimhash64(String text) {
    final fn = _simhashFn;
    if (fn == null) return null;
    final ptr = text.toNativeUtf8();
    try {
      return fn(ptr);
    } catch (e) {
      debugPrint('[Athena Rust Engine] computeSimhash64 failed: $e');
      return null;
    } finally {
      calloc.free(ptr);
    }
  }

  /// Plans chunks via Rust DP chunker, returning JSON map or null for fallback.
  Map<String, dynamic>? planChunksUtf8(
    String text, {
    int startPage = 1,
    int endPage = 1,
    int startSequence = 1,
    int startOffset = 0,
    bool isLastWindow = true,
    int targetLen = 240,
    int maxLen = 500,
  }) {
    final fn = _planChunksFn;
    if (fn == null) return null;
    final textPtr = text.toNativeUtf8();
    try {
      final res = fn(
        textPtr,
        startPage,
        endPage,
        startSequence,
        startOffset,
        isLastWindow,
        targetLen,
        maxLen,
      );
      if (res.statusCode != 0 || res.jsonPayload == ffi.nullptr) {
        return null;
      }
      final jsonStr = res.jsonPayload.toDartString();
      _freeStringFn?.call(res.jsonPayload);
      return jsonDecode(jsonStr) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('[Athena Rust Engine] planChunksUtf8 failed: $e');
      return null;
    } finally {
      calloc.free(textPtr);
    }
  }

  /// Ingests EPUB streaming spine window via Rust, returning JSON string or null.
  String? ingestEpubWindowed(String path, {int startSpine = 0, int count = 10}) {
    final fn = _ingestEpubFn;
    if (fn == null) return null;
    final pathPtr = path.toNativeUtf8();
    try {
      final resPtr = fn(pathPtr, startSpine, count);
      if (resPtr == ffi.nullptr) return null;
      final resultStr = resPtr.toDartString();
      _freeStringFn?.call(resPtr);
      return resultStr;
    } catch (e) {
      debugPrint('[Athena Rust Engine] ingestEpubWindowed failed: $e');
      return null;
    } finally {
      calloc.free(pathPtr);
    }
  }

  /// Commits window batch to SQLite directly in Rust, returning new chain hash.
  String? commitWindowBatch({
    required String dbPath,
    required String docId,
    required int windowPageStart,
    required int windowPageEnd,
    required String chunksJson,
    String carryOver = '',
    String prevChainHash = '',
    String status = 'processing',
  }) {
    final fn = _commitWindowFn;
    if (fn == null) return null;
    final dbPtr = dbPath.toNativeUtf8();
    final docPtr = docId.toNativeUtf8();
    final chunksPtr = chunksJson.toNativeUtf8();
    final coPtr = carryOver.toNativeUtf8();
    final pchPtr = prevChainHash.toNativeUtf8();
    final stPtr = status.toNativeUtf8();
    try {
      final resPtr = fn(
        dbPtr,
        docPtr,
        windowPageStart,
        windowPageEnd,
        chunksPtr,
        coPtr,
        pchPtr,
        stPtr,
      );
      if (resPtr == ffi.nullptr) return null;
      final result = resPtr.toDartString();
      _freeStringFn?.call(resPtr);
      return result;
    } catch (e) {
      debugPrint('[Athena Rust Engine] commitWindowBatch failed: $e');
      return null;
    } finally {
      calloc.free(dbPtr);
      calloc.free(docPtr);
      calloc.free(chunksPtr);
      calloc.free(coPtr);
      calloc.free(pchPtr);
      calloc.free(stPtr);
    }
  }
}
