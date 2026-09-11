import 'package:flutter/material.dart';

import 'ui/shell.dart';
import 'ui/theme.dart';

class YapApp extends StatelessWidget {
  const YapApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Yap',
        debugShowCheckedModeBanner: false,
        theme: YapTheme.light(),
        darkTheme: YapTheme.dark(),
        themeMode: ThemeMode.system,
        home: const AppShell(),
      );
}
