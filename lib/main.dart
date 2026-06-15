import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'services/proot_service.dart';
import 'services/terminal_service.dart';
import 'screens/home_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const LinuxContainerApp());
}

class LinuxContainerApp extends StatelessWidget {
  const LinuxContainerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ProotService()),
        ChangeNotifierProvider(create: (_) => TerminalService()),
      ],
      child: MaterialApp(
        title: "Linux Container v9.5",
        debugShowCheckedModeBanner: false,
        theme: _buildTheme(Brightness.dark),
        darkTheme: _buildTheme(Brightness.dark),
        themeMode: ThemeMode.dark,
        home: const HomeScreen(),
      ),
    );
  }

  ThemeData _buildTheme(Brightness brightness) {
    final isDark = brightness == Brightness.dark;

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorSchemeSeed: Colors.teal,
      scaffoldBackgroundColor: isDark ? const Color(0xFF0D1117) : null,
      appBarTheme: AppBarTheme(
        backgroundColor: isDark ? const Color(0xFF161B22) : null,
        centerTitle: true,
        elevation: 0,
      ),
      cardTheme: CardThemeData(
        color: isDark ? const Color(0xFF161B22) : null,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(
            color: (isDark ? Colors.white : Colors.black).withValues(alpha: 0.06),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        filled: true,
        fillColor: isDark ? const Color(0xFF21262D) : null,
      ),
    );
  }
}
