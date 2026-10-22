import 'package:flutter/material.dart';

import 'api.dart';
import 'screens/dashboard.dart';
import 'screens/settings_screen.dart';

void main() => runApp(const NasHubApp());

class NasHubApp extends StatelessWidget {
  const NasHubApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'NAS Hub',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorSchemeSeed: Colors.indigo,
          brightness: Brightness.dark,
          useMaterial3: true,
        ),
        home: const Root(),
      );
}

class Root extends StatefulWidget {
  const Root({super.key});
  @override
  State<Root> createState() => _RootState();
}

class _RootState extends State<Root> {
  Settings? settings;

  @override
  void initState() {
    super.initState();
    Settings.load().then((s) => setState(() => settings = s));
  }

  Future<void> _openSettings() async {
    final s = await Navigator.push<Settings>(
      context,
      MaterialPageRoute(builder: (_) => SettingsScreen(initial: settings!)),
    );
    if (s != null) setState(() => settings = s);
  }

  @override
  Widget build(BuildContext context) {
    final s = settings;
    if (s == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (!s.isSet) return SettingsScreen(initial: s, firstRun: true, onSaved: (n) => setState(() => settings = n));
    return Dashboard(api: Api(s), onSettings: _openSettings);
  }
}
