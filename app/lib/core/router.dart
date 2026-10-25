import 'package:go_router/go_router.dart';
import 'package:athena/features/library/screens/library_screen.dart';
import 'package:athena/features/processing/screens/processing_screen.dart';
import 'package:athena/features/reader/screens/reader_screen.dart';
import 'package:athena/features/saved/screens/saved_screen.dart';
import 'package:athena/features/settings/screens/connection_setup_screen.dart';

/// Navigation: / Library · /processing/:id · /reader/:id?chunk= · /saved · /settings
final appRouter = GoRouter(
  initialLocation: '/',
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
);
