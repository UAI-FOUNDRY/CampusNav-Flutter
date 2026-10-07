import 'package:flutter/material.dart';
import 'screens/app_shell.dart';
import 'theme/app_theme.dart';

void main() => runApp(const CampusNavApp());

class CampusNavApp extends StatelessWidget {
  const CampusNavApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Campus Navigation',
      theme: AppTheme.light(),
      home: const AppShell(),
    );
  }
}
