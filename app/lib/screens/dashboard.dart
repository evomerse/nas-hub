import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import 'containers.dart';
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
  List<ProcUsage> procs = [];
  int _tick = 0;
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
        // Les processus changent lentement et coûtent plus cher à lister : un tour sur trois.
        if (_tick++ % 3 == 0) procs = await widget.api.processes();
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

  /// Stats du NAS (CPU, RAM, réseau, disques).
  List<Widget> _systemSection(BuildContext context) {
    final st = stats;
    if (st == null) {
      return [
        if (widget.api.s.hasAgent && error == null)
          const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator())),
      ];
    }
    return [
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
      if (procs.isNotEmpty) _ProcessesCard(procs: procs),
      _NetworkCard(stats: st),
      const SizedBox(height: 4),
      Text('Stockage', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 8),
      for (final dk in st.disks) _DiskCard(disk: dk),
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text('Allumé depuis ${_uptime(st.uptimeS)}', style: Theme.of(context).textTheme.bodySmall),
      ),
    ];
  }

  /// Lectures Jellyfin et appareils connectés.
  List<Widget> _mediaSection(BuildContext context) => [
        if (widget.api.s.hasJellyfin) ...[
          Text('En lecture sur Jellyfin', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (sessions.isEmpty)
            const Padding(padding: EdgeInsets.all(16), child: Text('Personne ne regarde quoi que ce soit.')),
          for (final s in sessions) _SessionCard(session: s, api: widget.api),
          const SizedBox(height: 16),
        ],
        DevicesSection(api: widget.api),
        const SizedBox(height: 16),
        ContainersSection(api: widget.api),
        const SizedBox(height: 24),
      ];

  Widget _errorBanner(BuildContext context) => Card(
        color: Theme.of(context).colorScheme.errorContainer,
        child: Padding(padding: const EdgeInsets.all(12), child: Text(error!)),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('NAS Hub'),
        actions: [IconButton(icon: const Icon(Icons.settings), onPressed: widget.onSettings)],
      ),
      body: LayoutBuilder(builder: (context, box) {
        // Grand écran (PC) : stats à gauche, Jellyfin et appareils à droite. Téléphone : une colonne.
        if (box.maxWidth >= 900) {
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1300),
              child: Column(children: [
                if (error != null) Padding(padding: const EdgeInsets.fromLTRB(12, 12, 12, 0), child: _errorBanner(context)),
                Expanded(
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(child: ListView(padding: const EdgeInsets.all(12), children: _systemSection(context))),
                    Expanded(child: ListView(padding: const EdgeInsets.all(12), children: _mediaSection(context))),
                  ]),
                ),
              ]),
            ),
          );
        }
        return RefreshIndicator(
          onRefresh: _refresh,
          child: ListView(padding: const EdgeInsets.all(12), children: [
            if (error != null) _errorBanner(context),
            ..._systemSection(context),
            const SizedBox(height: 8),
            ..._mediaSection(context),
          ]),
        );
      }),
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

class _DiskCard extends StatelessWidget {
  final Disk disk;
  const _DiskCard({required this.disk});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final info = [
      if (disk.path.isNotEmpty) disk.path,
      if (disk.device.isNotEmpty) disk.device,
      if (disk.fstype.isNotEmpty) disk.fstype,
    ].join(' · ');
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Row(children: [const Icon(Icons.storage, size: 18), const SizedBox(width: 8), Text(disk.name, style: t.labelLarge)]),
            Text('${disk.percent.toStringAsFixed(0)} %'),
          ]),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: disk.percent / 100,
            minHeight: 8,
            borderRadius: BorderRadius.circular(4),
            color: disk.percent > 90 ? Colors.redAccent : null,
          ),
          const SizedBox(height: 6),
          Text('${_bytes(disk.used)} utilisés sur ${_bytes(disk.total)}  ·  ${_bytes(disk.total - disk.used)} libres',
              style: t.bodySmall),
          if (info.isNotEmpty) Text(info, style: t.bodySmall?.copyWith(color: Colors.white38)),
        ]),
      ),
    );
  }
}

class _ProcessesCard extends StatelessWidget {
  final List<ProcUsage> procs;
  const _ProcessesCard({required this.procs});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final top = procs.first.ram;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Programmes les plus gourmands (RAM)', style: t.labelLarge),
          const SizedBox(height: 10),
          for (final p in procs)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Icon(p.kind == 'container' ? Icons.inventory_2 : Icons.memory, size: 14, color: Colors.white54),
                  const SizedBox(width: 6),
                  Expanded(child: Text(p.name, overflow: TextOverflow.ellipsis)),
                  Text('${_bytes(p.ram)}  ·  ${p.percent.toStringAsFixed(1)} %', style: t.bodySmall),
                ]),
                const SizedBox(height: 3),
                LinearProgressIndicator(
                    value: top > 0 ? p.ram / top : 0, minHeight: 5, borderRadius: BorderRadius.circular(3)),
              ]),
            ),
        ]),
      ),
    );
  }
}

class _NetworkCard extends StatelessWidget {
  final SystemStats stats;
  const _NetworkCard({required this.stats});

  static const down = Color(0xFF4FC3F7);
  static const up = Color(0xFFFFB74D);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final minutes = (stats.downHistory.length * stats.netIntervalS / 60).round();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.network_check, size: 18),
            const SizedBox(width: 8),
            Text('Réseau', style: t.labelLarge),
            const Spacer(),
            Text(minutes > 0 ? 'dernières $minutes min' : 'en cours de mesure', style: t.bodySmall),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            _Rate(label: 'Réception', value: stats.downBps, color: down, icon: Icons.arrow_downward),
            const SizedBox(width: 24),
            _Rate(label: 'Envoi', value: stats.upBps, color: up, icon: Icons.arrow_upward),
          ]),
          const SizedBox(height: 12),
          SizedBox(
            height: 140,
            child: CustomPaint(
              size: Size.infinite,
              painter: _ChartPainter(down: stats.downHistory, up: stats.upHistory, downColor: down, upColor: up),
            ),
          ),
        ]),
      ),
    );
  }
}

class _Rate extends StatelessWidget {
  final String label;
  final double value;
  final Color color;
  final IconData icon;
  const _Rate({required this.label, required this.value, required this.color, required this.icon});

  @override
  Widget build(BuildContext context) => Row(children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 6),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: Theme.of(context).textTheme.bodySmall),
          Text('${_bytes(value.round())}/s', style: Theme.of(context).textTheme.titleMedium?.copyWith(color: color)),
        ]),
      ]);
}

/// Courbes de débit (réception et envoi), échelle ajustée au maximum observé.
class _ChartPainter extends CustomPainter {
  final List<double> down, up;
  final Color downColor, upColor;
  _ChartPainter({required this.down, required this.up, required this.downColor, required this.upColor});

  /// Plafond arrondi à 1, 2 ou 5 × 10^n, avec un minimum de 100 Ko/s pour éviter un bruit exagéré.
  double _ceiling(double m) {
    if (m < 100 * 1024) return 100 * 1024;
    var p = 1.0;
    while (p * 10 <= m) {
      p *= 10;
    }
    for (final k in [1.0, 2.0, 5.0, 10.0]) {
      if (k * p >= m) return k * p;
    }
    return 10 * p;
  }

  @override
  void paint(Canvas canvas, Size size) {
    const labelW = 56.0;
    final plot = Rect.fromLTWH(labelW, 4, size.width - labelW, size.height - 8);
    final maxV = _ceiling([...down, ...up].fold<double>(0, (a, b) => b > a ? b : a));

    final grid = Paint()
      ..color = Colors.white12
      ..strokeWidth = 1;
    for (var i = 0; i <= 2; i++) {
      final y = plot.top + plot.height * i / 2;
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), grid);
      final tp = TextPainter(
        text: TextSpan(
            text: '${_bytes((maxV * (1 - i / 2)).round())}/s',
            style: const TextStyle(fontSize: 10, color: Colors.white54)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(0, y - tp.height / 2));
    }

    void series(List<double> v, Color c) {
      if (v.length < 2) return;
      final dx = plot.width / (v.length - 1);
      final line = Path();
      for (var i = 0; i < v.length; i++) {
        final x = plot.left + dx * i;
        final y = plot.bottom - (v[i] / maxV).clamp(0.0, 1.0) * plot.height;
        i == 0 ? line.moveTo(x, y) : line.lineTo(x, y);
      }
      final fill = Path.from(line)
        ..lineTo(plot.right, plot.bottom)
        ..lineTo(plot.left, plot.bottom)
        ..close();
      canvas.drawPath(fill, Paint()..color = c.withValues(alpha: 0.15));
      canvas.drawPath(
          line,
          Paint()
            ..color = c
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..strokeJoin = StrokeJoin.round);
    }

    series(down, downColor);
    series(up, upColor);
  }

  @override
  bool shouldRepaint(_ChartPainter old) => old.down != down || old.up != up;
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
