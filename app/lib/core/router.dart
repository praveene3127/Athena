import 'package:go_router/go_router.dart';
import '../features/library/library_screen.dart';
import '../features/processing/processing_screen.dart';
import '../features/reader/reader_screen.dart';
import '../features/saved/saved_screen.dart';
import '../features/settings/connection_setup_screen.dart';

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
