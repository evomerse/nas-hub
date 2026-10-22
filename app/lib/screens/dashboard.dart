import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import 'devices.dart';

class Dashboard extends StatefulWidget {
  final Api api;
  final VoidCallback onSettings;
  const Dashboard({super.key, required this.api, required this.onSettings});

  @override
  State<Dashboard> createState() => _DashboardState();
}

class _DashboardState extends State<Dashboard> {
  SystemStats? stats;
  List<PlaySession> sessions = [];
  String? error;
  Timer? _timer;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_busy) return;
    _busy = true;
    // Chaque source est indépendante : une panne de l'une n'efface pas l'autre.
    final errors = <String>[];
    if (widget.api.s.hasAgent) {
      try {
        stats = await widget.api.system();
      } catch (e) {
        errors.add('Agent : $e');
      }
    }
    if (widget.api.s.hasJellyfin) {
      try {
        final fresh = await widget.api.sessions();
        // On garde l'ancien objet si rien n'a changé, pour que le compteur ne saute pas.
        sessions = [for (final n in fresh) sessions.firstWhere((o) => o.sameAs(n), orElse: () => n)];
      } catch (e) {
        errors.add('Jellyfin : $e');
      }
    }
    if (mounted) setState(() => error = errors.isEmpty ? null : errors.join('\n'));
    _busy = false;
  }

  @override
  Widget build(BuildContext context) {
    final st = stats;
    return Scaffold(
      appBar: AppBar(
        title: const Text('NAS Hub'),
        actions: [IconButton(icon: const Icon(Icons.settings), onPressed: widget.onSettings)],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(padding: const EdgeInsets.all(12), children: [
          if (error != null)
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(padding: const EdgeInsets.all(12), child: Text(error!)),
            ),
          if (st != null) ...[
            Row(children: [
              Expanded(child: _Gauge(label: 'CPU', value: st.cpu, text: '${st.cpu.toStringAsFixed(0)} %')),
              const SizedBox(width: 12),
              Expanded(
                child: _Gauge(
                  label: 'Température',
                  value: st.temp == null ? 0 : st.temp!.clamp(0, 100).toDouble(),
                  text: st.temp == null ? 'n/a' : '${st.temp!.toStringAsFixed(0)} °C',
                  color: _tempColor(st.temp),
                ),
              ),
            ]),
            const SizedBox(height: 12),
            _Bar(
              label: 'RAM',
              percent: st.ramPercent,
              detail: '${_bytes(st.ramUsed)} / ${_bytes(st.ramTotal)}',
            ),
            for (final d in st.disks)
              _Bar(label: d.name, percent: d.percent, detail: '${_bytes(d.used)} / ${_bytes(d.total)}'),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                '↓ ${_bytes(st.downBps.round())}/s   ↑ ${_bytes(st.upBps.round())}/s   ·   allumé depuis ${_uptime(st.uptimeS)}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ] else if (error == null)
            const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator())),
          if (widget.api.s.hasJellyfin) ...[
            const SizedBox(height: 8),
            Text('En lecture sur Jellyfin', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (sessions.isEmpty)
              const Padding(padding: EdgeInsets.all(16), child: Text('Personne ne regarde quoi que ce soit.')),
            for (final s in sessions) _SessionCard(session: s, api: widget.api),
          ],
          const SizedBox(height: 16),
          DevicesSection(api: widget.api),
          const SizedBox(height: 24),
        ]),
      ),
    );
  }
}

Color _tempColor(double? t) {
  if (t == null) return Colors.grey;
  if (t < 60) return Colors.greenAccent;
  if (t < 75) return Colors.orangeAccent;
  return Colors.redAccent;
}

String _bytes(num b) {
  const u = ['o', 'Ko', 'Mo', 'Go', 'To'];
  var i = 0;
  var v = b.toDouble();
  while (v >= 1024 && i < u.length - 1) { v /= 1024; i++; }
  return '${v.toStringAsFixed(i < 3 ? 0 : 1)} ${u[i]}';
}

String _uptime(int s) {
  final d = s ~/ 86400, h = s % 86400 ~/ 3600;
  return d > 0 ? '${d}j ${h}h' : '${h}h ${s % 3600 ~/ 60}min';
}

String _clock(int s) {
  final h = s ~/ 3600, m = s % 3600 ~/ 60, sec = s % 60;
  final mm = m.toString().padLeft(2, '0'), ss = sec.toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss' : '$m:$ss';
}

class _Gauge extends StatelessWidget {
  final String label, text;
  final double value; // 0..100
  final Color? color;
  const _Gauge({required this.label, required this.value, required this.text, this.color});

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(children: [
            Text(label, style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 12),
            SizedBox(
              width: 96,
              height: 96,
              child: Stack(alignment: Alignment.center, children: [
                SizedBox.expand(
                  child: CircularProgressIndicator(
                    value: value / 100,
                    strokeWidth: 9,
                    color: color,
                    backgroundColor: Colors.white12,
                  ),
                ),
                Text(text, style: Theme.of(context).textTheme.titleLarge),
              ]),
            ),
          ]),
        ),
      );
}

class _Bar extends StatelessWidget {
  final String label, detail;
  final double percent;
  const _Bar({required this.label, required this.percent, required this.detail});

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Text(label, style: Theme.of(context).textTheme.labelLarge),
              Text('${percent.toStringAsFixed(0)} %  ·  $detail'),
            ]),
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: percent / 100,
              minHeight: 8,
              borderRadius: BorderRadius.circular(4),
              color: percent > 90 ? Colors.redAccent : null,
            ),
          ]),
        ),
      );
}

class _SessionCard extends StatefulWidget {
  final PlaySession session;
  final Api api;
  const _SessionCard({required this.session, required this.api});

  @override
  State<_SessionCard> createState() => _SessionCardState();
}

class _SessionCardState extends State<_SessionCard> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // Fait avancer le compteur chaque seconde entre deux interrogations de Jellyfin.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && !widget.session.paused) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.session, api = widget.api;
    final now = DateTime.now();
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _showMessageDialog(context, api, s),
        child: Row(children: [
          if (s.imageId == null)
            const SizedBox(width: 90, height: 135, child: Icon(Icons.movie, size: 40))
          else
            Image.network(
              api.jellyfinImageUrl(s.imageId!),
              headers: api.jellyfinHeaders,
              width: 90,
              height: 135,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => const SizedBox(width: 90, height: 135, child: Icon(Icons.movie, size: 40)),
            ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: Text(s.user, style: Theme.of(context).textTheme.titleMedium)),
                  const Icon(Icons.chat_bubble_outline, size: 16),
                ]),
                const SizedBox(height: 2),
                Text(s.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                if (s.subtitle.isNotEmpty)
                  Text(s.subtitle, style: Theme.of(context).textTheme.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 6),
                Text(
                  '${s.paused ? '⏸ En pause' : '▶ Lecture'} · ${s.device}${s.transcoding ? ' · transcodage' : ''}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                LinearProgressIndicator(value: s.progressAt(now)),
                const SizedBox(height: 4),
                Text('${_clock(s.livePositionS(now))} / ${_clock(s.runtimeS)}',
                    style: Theme.of(context).textTheme.bodySmall),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}

/// Envoie un message affiché à l'écran de la session, comme dans l'interface Jellyfin.
Future<void> _showMessageDialog(BuildContext context, Api api, PlaySession s) async {
  final header = TextEditingController(text: 'Message');
  final text = TextEditingController();
  final seconds = TextEditingController(text: '10');
  final messenger = ScaffoldMessenger.of(context);
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Message à ${s.user}'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('Sur ${s.device}', style: Theme.of(ctx).textTheme.bodySmall),
          TextField(controller: header, decoration: const InputDecoration(labelText: 'Titre')),
          TextField(
            controller: text,
            autofocus: true,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(labelText: 'Message'),
          ),
          TextField(
            controller: seconds,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Durée d\'affichage (secondes)'),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Envoyer')),
      ],
    ),
  );
  if (ok != true || text.text.trim().isEmpty) return;
  final ms = (int.tryParse(seconds.text.trim()) ?? 10).clamp(1, 300) * 1000;
  try {
    await api.sendMessage(s.id, header.text.trim(), text.text.trim(), ms);
    messenger.showSnackBar(SnackBar(content: Text('Message envoyé à ${s.user}')));
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Échec : $e')));
  }
}
