import 'package:flutter/material.dart';

import '../api.dart';

/// Importe les appareils du compte Tuya IoT. Les identifiants servent uniquement à cette
/// recherche : ils ne sont stockés ni dans l'app ni sur l'agent.
class AddDevicesScreen extends StatefulWidget {
  final Api api;
  const AddDevicesScreen({super.key, required this.api});

  @override
  State<AddDevicesScreen> createState() => _AddDevicesScreenState();
}

class _AddDevicesScreenState extends State<AddDevicesScreen> {
  final accessId = TextEditingController();
  final secret = TextEditingController();
  final deviceId = TextEditingController();
  String region = 'eu';
  bool loading = false;
  String? error;
  List<FoundDevice>? found;
  final selected = <String>{};

  // LEDs Surplife / Magic Home (réseau local)
  bool scanning = false;
  String? scanError;
  List<LocalLight>? localFound;

  Future<void> _scanLocal() async {
    setState(() { scanning = true; scanError = null; });
    try {
      final l = await widget.api.scanLocal();
      setState(() => localFound = l);
    } catch (e) {
      setState(() => scanError = e.toString());
    } finally {
      setState(() => scanning = false);
    }
  }

  Future<void> _addLocal(LocalLight l) async {
    final name = TextEditingController(text: 'Bandeau LED');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Ajouter ces LEDs'),
        content: TextField(controller: name, decoration: const InputDecoration(labelText: 'Nom')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Ajouter')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await widget.api.addLocal(l, name.text.trim().isEmpty ? 'LEDs' : name.text.trim());
      await _scanLocal();
    } catch (e) {
      setState(() => scanError = e.toString());
    }
  }

  Future<void> _search() async {
    setState(() { loading = true; error = null; found = null; });
    try {
      final list = await widget.api.importFromTuya(
          accessId.text.trim(), secret.text.trim(), region, deviceId.text.trim());
      setState(() {
        found = list;
        selected
          ..clear()
          ..addAll(list.where((d) => !d.added).map((d) => d.id));
      });
    } catch (e) {
      setState(() => error = e.toString());
    } finally {
      setState(() => loading = false);
    }
  }

  Future<void> _add() async {
    setState(() => loading = true);
    try {
      await widget.api.addDevices(selected.toList());
      if (mounted) Navigator.pop(context);
    } catch (e) {
      setState(() { loading = false; error = e.toString(); });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final list = found;
    return Scaffold(
      appBar: AppBar(title: const Text('Ajouter des appareils')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text('LEDs Surplife / Magic Home', style: t.titleMedium),
        const SizedBox(height: 4),
        Text('Pas de compte à créer : l\'agent les trouve sur ton réseau Wi-Fi.', style: t.bodySmall),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: scanning ? null : _scanLocal,
          icon: scanning
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.wifi_find),
          label: const Text('Chercher sur le réseau'),
        ),
        if (scanError != null)
          Padding(padding: const EdgeInsets.only(top: 8), child: Text('✗ $scanError', style: const TextStyle(color: Colors.redAccent))),
        if (localFound != null && localFound!.isEmpty)
          const Padding(padding: EdgeInsets.only(top: 8), child: Text('Aucun contrôleur trouvé. Vérifie qu\'ils sont allumés et sur le même réseau que le NAS.')),
        for (final l in localFound ?? <LocalLight>[])
          ListTile(
            leading: const Icon(Icons.lightbulb),
            title: Text(l.model.isEmpty ? 'Contrôleur LED' : l.model),
            subtitle: Text('${l.ip} · ${l.mac}${l.added ? ' · déjà ajouté' : ''}'),
            trailing: l.added ? null : FilledButton(onPressed: () => _addLocal(l), child: const Text('Ajouter')),
          ),
        const Divider(height: 40),
        Text('Appareils Tuya / Smart Life (prise Konyks...)', style: t.titleMedium),
        const SizedBox(height: 8),
        Text('1. Sur iot.tuya.com, crée un projet cloud (Smart Home) et relie ton appli Smart Life '
            '(Devices > Link App Account). Le détail est dans le README.\n'
            '2. Recopie ici l\'Access ID et l\'Access Secret du projet, et l\'ID d\'un de tes appareils '
            '(Smart Life > appareil > ⋯ > Informations sur l\'appareil > ID virtuel).',
            style: t.bodySmall),
        const SizedBox(height: 8),
        TextField(controller: accessId, decoration: const InputDecoration(labelText: 'Access ID')),
        TextField(controller: secret, obscureText: true, decoration: const InputDecoration(labelText: 'Access Secret')),
        TextField(controller: deviceId, decoration: const InputDecoration(labelText: 'ID d\'un appareil')),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          initialValue: region,
          decoration: const InputDecoration(labelText: 'Datacenter du projet'),
          items: const [
            DropdownMenuItem(value: 'eu', child: Text('Europe centrale')),
            DropdownMenuItem(value: 'eu-w', child: Text('Europe de l\'ouest')),
            DropdownMenuItem(value: 'us', child: Text('États-Unis (ouest)')),
            DropdownMenuItem(value: 'us-e', child: Text('États-Unis (est)')),
            DropdownMenuItem(value: 'in', child: Text('Inde')),
            DropdownMenuItem(value: 'cn', child: Text('Chine')),
            DropdownMenuItem(value: 'sg', child: Text('Singapour')),
          ],
          onChanged: (v) => setState(() => region = v ?? 'eu'),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: loading ? null : _search,
          child: loading && list == null
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Rechercher mes appareils'),
        ),
        if (error != null)
          Padding(padding: const EdgeInsets.only(top: 12), child: Text('✗ $error', style: const TextStyle(color: Colors.redAccent))),
        if (list != null) ...[
          const SizedBox(height: 16),
          Text('${list.length} appareil(s) trouvé(s)', style: t.titleMedium),
          if (list.any((d) => d.ip.isEmpty))
            Text('Sans adresse IP trouvée sur le réseau, l\'agent essaiera de les localiser lui-même.',
                style: t.bodySmall),
          for (final d in list)
            CheckboxListTile(
              value: d.added || selected.contains(d.id),
              onChanged: d.added
                  ? null
                  : (v) => setState(() => v == true ? selected.add(d.id) : selected.remove(d.id)),
              title: Text(d.name),
              subtitle: Text('${d.kind == 'light' ? 'Lumière' : 'Prise'}${d.added ? ' · déjà ajouté' : ''}'),
              secondary: Icon(d.kind == 'light' ? Icons.lightbulb : Icons.power),
            ),
          if (list.isNotEmpty)
            FilledButton(
              onPressed: loading || selected.isEmpty ? null : _add,
              child: Text('Ajouter (${selected.length})'),
            ),
        ],
      ]),
    );
  }
}
