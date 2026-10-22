import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import 'add_devices.dart';

/// Section « Appareils » (LEDs, prises) affichée en bas du tableau de bord.
class DevicesSection extends StatefulWidget {
  final Api api;
  const DevicesSection({super.key, required this.api});

  @override
  State<DevicesSection> createState() => _DevicesSectionState();
}

class _DevicesSectionState extends State<DevicesSection> {
  List<Device>? devices;
  String? error;
  Timer? _timer;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_busy || !widget.api.s.hasAgent) return;
    _busy = true;
    try {
      final d = await widget.api.devices();
      if (mounted) setState(() { devices = d; error = null; });
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      _busy = false;
    }
  }

  /// Applique l'action puis recharge l'état réel de l'appareil.
  Future<void> _act(Future<void> Function() action) async {
    try {
      await action();
      await _refresh();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Échec : $e')));
    }
  }

  Future<void> _add() async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => AddDevicesScreen(api: widget.api)));
    _refresh();
  }

  Future<void> _remove(Device d) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Retirer « ${d.name} » ?'),
        content: const Text('Il disparaît de l\'app (il reste dans ton compte Tuya).'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Retirer')),
        ],
      ),
    );
    if (ok == true) _act(() => widget.api.removeDevice(d.id));
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final list = devices;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: Text('Appareils', style: t.titleMedium)),
        if (widget.api.s.hasAgent)
          TextButton.icon(onPressed: _add, icon: const Icon(Icons.add), label: const Text('Ajouter')),
      ]),
      if (!widget.api.s.hasAgent)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Text('Les appareils passent par l\'agent NAS. Renseigne son adresse dans les réglages.'),
        ),
      if (error != null)
        Card(
          color: Theme.of(context).colorScheme.errorContainer,
          child: Padding(padding: const EdgeInsets.all(12), child: Text(error!)),
        ),
      if (widget.api.s.hasAgent && list != null && list.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Text('Aucun appareil pour l\'instant. Touche « Ajouter » pour importer tes LEDs et ta prise.'),
        ),
      for (final d in list ?? <Device>[])
        _DeviceCard(
          key: ValueKey(d.id),
          device: d,
          onPower: (on) => _act(() => widget.api.setPower(d.id, on)),
          onBrightness: (v) => _act(() => widget.api.setBrightness(d.id, v)),
          onColor: (hex) => _act(() => widget.api.setColor(d.id, hex)),
          onWhite: (temp, b) => _act(() => widget.api.setWhite(d.id, temp, b)),
          onTimer: (secs) => _act(() => widget.api.setTimer(d.id, secs)),
          onRemove: () => _remove(d),
        ),
    ]);
  }
}

const _palette = <String, Color>{
  '#ff0000': Colors.red,
  '#ff7a00': Colors.orange,
  '#ffd000': Colors.yellow,
  '#00ff00': Colors.green,
  '#00ffd0': Colors.cyanAccent,
  '#0000ff': Colors.blue,
  '#8000ff': Colors.deepPurple,
  '#ff00aa': Colors.pinkAccent,
  '#ffffff': Colors.white,
};

String _hex(Color c) =>
    '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

String _countdown(int s) {
  final h = s ~/ 3600, m = s % 3600 ~/ 60, sec = s % 60;
  final mm = m.toString().padLeft(2, '0'), ss = sec.toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
}

class _DeviceCard extends StatefulWidget {
  final Device device;
  final ValueChanged<bool> onPower;
  final ValueChanged<int> onBrightness;
  final ValueChanged<String> onColor;
  final void Function(int temp, int brightness) onWhite;
  final ValueChanged<int> onTimer;
  final VoidCallback onRemove;
  const _DeviceCard({
    super.key,
    required this.device,
    required this.onPower,
    required this.onBrightness,
    required this.onColor,
    required this.onWhite,
    required this.onTimer,
    required this.onRemove,
  });

  @override
  State<_DeviceCard> createState() => _DeviceCardState();
}

class _DeviceCardState extends State<_DeviceCard> {
  double? _brightness; // pendant le glissement
  late double _hue, _sat;
  double _temp = 50;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _syncColor();
    // Fait avancer le compte à rebours de la prise entre deux rafraîchissements.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && widget.device.timer != null) setState(() {});
    });
  }

  @override
  void didUpdateWidget(_DeviceCard old) {
    super.didUpdateWidget(old);
    if (old.device.color != widget.device.color) _syncColor();
  }

  void _syncColor() {
    final c = widget.device.color;
    if (c != null) {
      final hsv = HSVColor.fromColor(Color(int.parse('ff${c.substring(1)}', radix: 16)));
      _hue = hsv.hue;
      _sat = hsv.saturation * 100;
    } else {
      _hue = 0;
      _sat = 100;
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  void _applyHsv() => widget.onColor(_hex(HSVColor.fromAHSV(1, _hue, _sat / 100, 1).toColor()));

  Future<void> _customTimer() async {
    final c = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Minuteur'),
        content: TextField(
          controller: c,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'Durée (minutes)'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Lancer')),
        ],
      ),
    );
    final m = int.tryParse(c.text.trim());
    if (ok == true && m != null && m > 0) widget.onTimer(m * 60);
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.device;
    final t = Theme.of(context).textTheme;
    final live = d.online && d.on;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(d.isLight ? Icons.lightbulb : Icons.power, color: live ? Colors.amber : Colors.grey),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(d.name, style: t.titleMedium),
                Text(d.online ? (d.on ? 'Allumé' : 'Éteint') : 'Hors ligne', style: t.bodySmall),
              ]),
            ),
            Switch(value: d.on, onChanged: d.online ? widget.onPower : null),
            PopupMenuButton<String>(
              onSelected: (_) => widget.onRemove(),
              itemBuilder: (_) => const [PopupMenuItem(value: 'remove', child: Text('Retirer de l\'app'))],
            ),
          ]),
          if (!d.online && d.error != null)
            Padding(padding: const EdgeInsets.only(top: 6), child: Text(d.error!, style: t.bodySmall)),
          if (d.isLight && live) ...[
            const SizedBox(height: 8),
            Text('Intensité', style: t.labelMedium),
            Slider(
              min: 1,
              max: 100,
              value: _brightness ?? (d.brightness ?? 100).toDouble(),
              onChanged: (v) => setState(() => _brightness = v),
              onChangeEnd: (v) {
                widget.onBrightness(v.round());
                setState(() => _brightness = null);
              },
            ),
            Text('Couleur', style: t.labelMedium),
            _GradientSlider(
              value: _hue,
              max: 360,
              colors: [for (var h = 0; h <= 360; h += 60) HSVColor.fromAHSV(1, h.toDouble(), 1, 1).toColor()],
              onChanged: (v) => setState(() => _hue = v),
              onChangeEnd: (_) => _applyHsv(),
            ),
            _GradientSlider(
              value: _sat,
              max: 100,
              colors: [Colors.white, HSVColor.fromAHSV(1, _hue, 1, 1).toColor()],
              onChanged: (v) => setState(() => _sat = v),
              onChangeEnd: (_) => _applyHsv(),
            ),
            const SizedBox(height: 4),
            Wrap(spacing: 10, runSpacing: 8, children: [
              for (final e in _palette.entries)
                GestureDetector(
                  onTap: () => widget.onColor(e.key),
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: e.value,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: d.color == e.key ? Colors.white : Colors.white24,
                        width: d.color == e.key ? 3 : 1,
                      ),
                    ),
                  ),
                ),
            ]),
            if (d.caps.contains('white')) ...[
              const SizedBox(height: 12),
              Text('Blanc (chaud → froid)${d.mode == 'white' ? '  ·  actif' : ''}', style: t.labelMedium),
              _GradientSlider(
                value: _temp,
                max: 100,
                colors: const [Color(0xFFFFB347), Colors.white, Color(0xFFB3D9FF)],
                onChanged: (v) => setState(() => _temp = v),
                onChangeEnd: (v) => widget.onWhite(v.round(), d.brightness ?? 100),
              ),
            ],
          ],
          if (!d.isLight && d.online) ...[
            const SizedBox(height: 8),
            if (d.timerLeft(DateTime.now()) > 0)
              Row(children: [
                const Icon(Icons.timer, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${d.on ? 'S\'éteint' : 'S\'allume'} dans ${_countdown(d.timerLeft(DateTime.now()))}',
                  ),
                ),
                TextButton(onPressed: () => widget.onTimer(0), child: const Text('Annuler')),
              ])
            else ...[
              Text('Minuteur (${d.on ? 'extinction' : 'allumage'})', style: t.labelMedium),
              const SizedBox(height: 4),
              Wrap(spacing: 8, children: [
                for (final e in const {'15 min': 900, '30 min': 1800, '1 h': 3600, '2 h': 7200}.entries)
                  ActionChip(label: Text(e.key), onPressed: () => widget.onTimer(e.value)),
                ActionChip(label: const Text('Autre…'), onPressed: _customTimer),
              ]),
            ],
          ],
        ]),
      ),
    );
  }
}

/// Curseur dont la piste est un dégradé (teinte, saturation, température).
class _GradientSlider extends StatelessWidget {
  final double value, max;
  final List<Color> colors;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;
  const _GradientSlider({
    required this.value,
    required this.max,
    required this.colors,
    required this.onChanged,
    required this.onChangeEnd,
  });

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 36,
        child: Stack(alignment: Alignment.center, children: [
          Container(
            height: 12,
            margin: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              gradient: LinearGradient(colors: colors),
            ),
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 12,
              activeTrackColor: Colors.transparent,
              inactiveTrackColor: Colors.transparent,
              thumbColor: Colors.white,
            ),
            child: Slider(value: value.clamp(0, max), min: 0, max: max, onChanged: onChanged, onChangeEnd: onChangeEnd),
          ),
        ]),
      );
}
