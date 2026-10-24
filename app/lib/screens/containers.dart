import 'package:flutter/material.dart';

import '../api.dart';

/// Section « Conteneurs » : la liste n'est chargée que quand on touche « Scanner »
/// (les nouveaux conteneurs apparaissent donc au scan suivant). Toucher un conteneur
/// ouvre le menu des commandes.
class ContainersSection extends StatefulWidget {
  final Api api;
  const ContainersSection({super.key, required this.api});

  @override
  State<ContainersSection> createState() => _ContainersSectionState();
}

class _ContainersSectionState extends State<ContainersSection> {
  List<DockerContainer>? containers;
  String? error;
  bool _scanning = false;
  final Set<String> _busy = {}; // conteneurs dont une commande est en cours
  DateTime? _scannedAt;

  Future<void> _scan() async {
    if (_scanning) return;
    setState(() => _scanning = true);
    try {
      final list = await widget.api.containers();
      if (mounted) setState(() { containers = list; error = null; _scannedAt = DateTime.now(); });
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  void _snack(String msg) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<bool> _confirm(String title, String text, String ok) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: Text(text),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(ok)),
          ],
        ),
      ) ==
      true;

  Future<void> _run(DockerContainer c, String action) async {
    final selfNote = c.isSelf ? '\n\nAttention : c\'est l\'agent NAS Hub lui-même, l\'app perdra la connexion.' : '';
    switch (action) {
      case 'stop':
        if (c.isSelf && !await _confirm('Arrêter ${c.name} ?', 'L\'app ne pourra plus le relancer.$selfNote', 'Arrêter')) return;
      case 'remove':
        if (!await _confirm('Supprimer ${c.name} ?',
            'Le conteneur est arrêté et supprimé. Ses volumes et son image sont conservés.$selfNote', 'Supprimer')) {
          return;
        }
      case 'rebuild':
        if (!await _confirm('Rebuild ${c.service ?? c.name} ?',
            'Équivaut à « docker compose up -d --build » (avec mise à jour de l\'image) pour ce service. '
                'Le conteneur sera recréé.$selfNote', 'Rebuild')) {
          return;
        }
    }
    setState(() => _busy.add(c.id));
    try {
      await widget.api.containerAction(c.id, action);
      _snack(switch (action) {
        'start' => '${c.name} démarré',
        'stop' => '${c.name} arrêté',
        'restart' => '${c.name} redémarré',
        'pause' => '${c.name} en pause',
        'unpause' => '${c.name} relancé',
        'remove' => '${c.name} supprimé',
        _ => 'Rebuild de ${c.name} lancé (le suivi est dans « Journal du rebuild »)',
      });
    } catch (e) {
      _snack('Échec : $e');
    } finally {
      if (mounted) setState(() => _busy.remove(c.id));
    }
    // Recharge la liste pour montrer le nouvel état.
    if (!(c.isSelf && action != 'rebuild')) await _scan();
  }

  Future<void> _menu(DockerContainer c) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final t = Theme.of(ctx).textTheme;
        Widget item(String value, IconData icon, String label, {bool enabled = true, Color? color}) => ListTile(
              leading: Icon(icon, color: enabled ? color : null),
              title: Text(label, style: color != null && enabled ? TextStyle(color: color) : null),
              enabled: enabled,
              onTap: () => Navigator.pop(ctx, value),
            );
        return SafeArea(
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(c.name, style: t.titleMedium),
                  Text(c.image, style: t.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                  Text(c.status, style: t.bodySmall),
                ]),
              ),
              const Divider(height: 1),
              if (c.running) ...[
                item('restart', Icons.restart_alt, 'Redémarrer'),
                item('stop', Icons.stop_circle_outlined, 'Arrêter'),
                item('pause', Icons.pause_circle_outline, 'Mettre en pause'),
              ] else if (c.paused)
                item('unpause', Icons.play_circle_outline, 'Reprendre')
              else
                item('start', Icons.play_arrow, 'Démarrer'),
              if (c.canRebuild)
                item('rebuild', Icons.build_circle_outlined,
                    c.rebuilding ? 'Rebuild en cours…' : 'Rebuild (compose up --build)',
                    enabled: !c.rebuilding),
              item('logs', Icons.article_outlined, 'Voir les logs'),
              if (c.rebuildState != null) item('rebuild-logs', Icons.receipt_long, 'Journal du rebuild'),
              item('remove', Icons.delete_outline, 'Supprimer le conteneur', color: Colors.redAccent),
            ]),
          ),
        );
      },
    );
    if (action == null || !mounted) return;
    if (action == 'logs' || action == 'rebuild-logs') {
      await _showLogs(c, rebuild: action == 'rebuild-logs');
      if (action == 'rebuild-logs') _scan(); // l'état du rebuild a pu changer
    } else {
      await _run(c, action);
    }
  }

  Future<void> _showLogs(DockerContainer c, {required bool rebuild}) => showDialog(
        context: context,
        builder: (_) => _LogsDialog(api: widget.api, container: c, rebuild: rebuild),
      );

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final list = containers;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: Text('Conteneurs', style: t.titleMedium)),
        if (widget.api.s.hasAgent)
          TextButton.icon(
            onPressed: _scanning ? null : _scan,
            icon: _scanning
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.radar),
            label: const Text('Scanner'),
          ),
      ]),
      if (!widget.api.s.hasAgent)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Text('Les conteneurs passent par l\'agent NAS. Renseigne son adresse dans les réglages.'),
        ),
      if (error != null)
        Card(
          color: Theme.of(context).colorScheme.errorContainer,
          child: Padding(padding: const EdgeInsets.all(12), child: Text(error!)),
        ),
      if (widget.api.s.hasAgent && list == null && error == null)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Text('Touche « Scanner » pour lister les conteneurs Docker du NAS.'),
        ),
      if (list != null && list.isEmpty) const Padding(padding: EdgeInsets.all(8), child: Text('Aucun conteneur.')),
      if (list != null && list.isNotEmpty) ...[
        Card(
          clipBehavior: Clip.antiAlias,
          child: Column(children: [
            for (final (i, c) in list.indexed) ...[
              if (i > 0) const Divider(height: 1),
              _ContainerTile(container: c, busy: _busy.contains(c.id), onTap: () => _menu(c)),
            ],
          ]),
        ),
        Padding(
          padding: const EdgeInsets.only(left: 4, top: 2),
          child: Text(
            '${list.where((c) => c.running).length} en marche sur ${list.length}'
            '${_scannedAt != null ? '  ·  scanné à ${_hm(_scannedAt!)}' : ''}',
            style: t.bodySmall,
          ),
        ),
      ],
    ]);
  }
}

String _hm(DateTime d) => '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

Color _stateColor(DockerContainer c) => switch (c.state) {
      'running' => Colors.greenAccent,
      'paused' => Colors.amber,
      'restarting' => Colors.orangeAccent,
      'dead' => Colors.redAccent,
      _ => Colors.grey,
    };

class _ContainerTile extends StatelessWidget {
  final DockerContainer container;
  final bool busy;
  final VoidCallback onTap;
  const _ContainerTile({required this.container, required this.busy, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = container;
    final t = Theme.of(context).textTheme;
    final sub = [
      c.status,
      if (c.project != null) c.project!,
      if (c.rebuilding) 'rebuild en cours',
      if (c.rebuildState == 'error') 'rebuild échoué',
    ].join('  ·  ');
    return ListTile(
      onTap: busy ? null : onTap,
      leading: Icon(Icons.inventory_2, color: _stateColor(c)),
      title: Text(c.name, overflow: TextOverflow.ellipsis),
      subtitle: Text(sub,
          style: t.bodySmall?.copyWith(color: c.rebuildState == 'error' ? Colors.redAccent : null),
          maxLines: 2,
          overflow: TextOverflow.ellipsis),
      trailing: busy || c.rebuilding
          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.more_vert),
    );
  }
}

/// Dernières lignes des logs (ou du rebuild), avec un bouton pour recharger.
class _LogsDialog extends StatefulWidget {
  final Api api;
  final DockerContainer container;
  final bool rebuild;
  const _LogsDialog({required this.api, required this.container, required this.rebuild});

  @override
  State<_LogsDialog> createState() => _LogsDialogState();
}

class _LogsDialogState extends State<_LogsDialog> {
  String? text;
  bool _loading = false;
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    String v;
    try {
      v = await widget.api.containerLogs(widget.container.id, rebuild: widget.rebuild);
      if (v.trim().isEmpty) v = '(aucune ligne)';
    } catch (e) {
      v = 'Échec : $e';
    }
    if (!mounted) return;
    setState(() { text = v; _loading = false; });
    // Affiche la fin du journal (le plus récent).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 900, maxHeight: size.height * 0.85),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 8, 4),
            child: Row(children: [
              Expanded(
                child: Text('${widget.rebuild ? 'Rebuild' : 'Logs'} · ${widget.container.name}',
                    style: Theme.of(context).textTheme.titleMedium, overflow: TextOverflow.ellipsis),
              ),
              IconButton(onPressed: _loading ? null : _load, icon: const Icon(Icons.refresh), tooltip: 'Recharger'),
              IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
            ]),
          ),
          const Divider(height: 1),
          Flexible(
            child: text == null
                ? const Padding(padding: EdgeInsets.all(32), child: CircularProgressIndicator())
                : Scrollbar(
                    controller: _scroll,
                    child: SingleChildScrollView(
                      controller: _scroll,
                      padding: const EdgeInsets.all(12),
                      child: SelectableText(text!,
                          style: const TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.3)),
                    ),
                  ),
          ),
        ]),
      ),
    );
  }
}
