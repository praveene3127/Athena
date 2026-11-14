import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:athena/core/theme/theme.dart';
import 'package:athena/core/router.dart';

class AthenaApp extends ConsumerWidget {
  const AthenaApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appearance = ref.watch(athenaAppearanceProvider);
    final theme = AppTheme.themeForAppearance(appearance);

    return MaterialApp.router(
      title: 'Athena',
      debugShowCheckedModeBanner: false,
      theme: theme,
      darkTheme: AppTheme.themeForAppearance(
        appearance.isDark ? appearance : AthenaAppearance.charcoal,
      ),
      themeMode: appearance.themeMode,
      routerConfig: appRouter,
    );
  }
}
