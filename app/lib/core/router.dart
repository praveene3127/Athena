import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:athena/features/library/screens/library_screen.dart';
import 'package:athena/features/processing/screens/processing_screen.dart';
import 'package:athena/features/reader/screens/reader_screen.dart';
import 'package:athena/features/saved/screens/saved_screen.dart';
import 'package:athena/features/settings/screens/connection_setup_screen.dart';

/// Navigation: / Library · /processing/:id · /reader/:id?chunk= · /saved · /settings
final appRouter = GoRouter(
  initialLocation: () {
    final route = ui.PlatformDispatcher.instance.defaultRouteName;
    if (route.isNotEmpty && route != '/') {
      return route;
    }
    return '/';
  }(),
  routes: [
    GoRoute(
      path: '/',
      builder: (context, state) => const LibraryScreen(),
    ),
    GoRoute(
      path: '/processing/:id',
      builder: (context, state) {
        final id = state.pathParameters['id']!;
        return ProcessingScreen(documentId: id);
      },
    ),
    GoRoute(
      path: '/reader',
      builder: (context, state) {
        final id = state.uri.queryParameters['id'] ?? '';
        final chunk = state.uri.queryParameters['chunk'];
        return ReaderScreen(documentId: id, initialChunkId: chunk);
      },
    ),
    GoRoute(
      path: '/reader/:id',
      builder: (context, state) {
        final id = state.pathParameters['id']!;
        final chunk = state.uri.queryParameters['chunk'];
        return ReaderScreen(documentId: id, initialChunkId: chunk);
      },
    ),
    GoRoute(
      path: '/saved',
      builder: (context, state) => const SavedScreen(),
    ),
    GoRoute(
      path: '/settings',
      builder: (context, state) => const ConnectionSetupScreen(),
    ),
  ],
  errorBuilder: (context, state) => Scaffold(
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Page Not Found',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              state.uri.toString(),
              style: const TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () => context.go('/'),
              child: const Text('Return to Library'),
            ),
          ],
        ),
      ),
    ),
  ),
);
