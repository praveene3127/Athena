import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app.dart';
import 'services/local_client_factory.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await initializeMobileProcessing();
  } catch (_) {
    // The app can still process in the foreground if background scheduling
    // is unavailable on this OS/device.
  }
  runApp(
    const ProviderScope(
      child: AthenaApp(),
    ),
  );
}
