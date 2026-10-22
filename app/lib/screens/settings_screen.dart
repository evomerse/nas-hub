import 'package:flutter/material.dart';

import '../api.dart';

class SettingsScreen extends StatefulWidget {
  final Settings initial;
  final bool firstRun;
  final void Function(Settings)? onSaved;
  const SettingsScreen(
      {super.key, required this.initial, this.firstRun = false, this.onSaved});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final agentUrl = TextEditingController(text: widget.initial.agentUrl);
  late final agentToken =
      TextEditingController(text: widget.initial.agentToken);
  late final jfUrl = TextEditingController(text: widget.initial.jellyfinUrl);
  late final jfKey = TextEditingController(text: widget.initial.jellyfinKey);
  String? agentStatus, jfStatus;
  bool testing = false;

  Settings get _current => Settings(
        agentUrl: Settings.normalizeUrl(agentUrl.text),
        agentToken: agentToken.text.trim(),
        jellyfinUrl: Settings.normalizeUrl(jfUrl.text),
        jellyfinKey: jfKey.text.trim(),
      );

  Future<void> _test() async {
    final s = _current;
    setState(() {
      testing = true;
      agentStatus = jfStatus = null;
    });
    final a = s.hasAgent
        ? await Api.testAgent(s.agentUrl, s.agentToken)
        : 'non configuré';
    final j = s.hasJellyfin
        ? await Api.testJellyfin(s.jellyfinUrl, s.jellyfinKey)
        : 'non configuré';
    if (!mounted) return;
    setState(() {
      testing = false;
      agentStatus = s.hasAgent ? (a ?? 'OK') : a;
      jfStatus = s.hasJellyfin ? (j ?? 'OK') : j;
    });
  }

  Future<void> _save() async {
    final s = _current;
    await s.save();
    if (widget.onSaved != null) {
      widget.onSaved!(s);
    } else if (mounted) {
      Navigator.pop(context, s);
    }
  }

  Widget _status(String? s) {
    if (s == null) return const SizedBox.shrink();
    final ok = s == 'OK';
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text(ok ? '✓ Connexion réussie' : '✗ $s',
          style: TextStyle(
              color: ok
                  ? Colors.greenAccent
                  : (s == 'non configuré' ? Colors.grey : Colors.redAccent))),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: Text(widget.firstRun ? 'Bienvenue' : 'Réglages')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: ListView(padding: const EdgeInsets.all(16), children: [
            Text('Jellyfin', style: t.titleMedium),
            const SizedBox(height: 4),
            Text(
                'Pour voir qui regarde quoi. Crée une clé dans Jellyfin : Tableau de bord > Clés API. '
                'Elle reste stockée sur cet appareil.',
                style: t.bodySmall),
            const SizedBox(height: 8),
            TextField(
              controller: jfUrl,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                  labelText: 'Adresse de Jellyfin',
                  hintText: '192.168.1.20:8096'),
            ),
            TextField(
              controller: jfKey,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Clé API Jellyfin'),
            ),
            _status(jfStatus),
            const SizedBox(height: 24),
            Text('Agent NAS (facultatif)', style: t.titleMedium),
            const SizedBox(height: 4),
            Text(
                'Pour le CPU, la température, la RAM et le stockage. Installe le conteneur '
                '« nas-hub-agent » sur ton NAS (voir le README).',
                style: t.bodySmall),
            const SizedBox(height: 8),
            TextField(
              controller: agentUrl,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                  labelText: 'Adresse de l\'agent',
                  hintText: '192.168.1.20:8787'),
            ),
            TextField(
              controller: agentToken,
              obscureText: true,
              decoration: const InputDecoration(
                  labelText: 'Token de l\'agent (si défini)'),
            ),
            _status(agentStatus),
            const SizedBox(height: 24),
            Row(children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: testing ? null : _test,
                  child: testing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Tester'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                  child: FilledButton(
                      onPressed: _save, child: const Text('Enregistrer'))),
            ]),
          ]),
        ),
      ),
    );
  }
}
