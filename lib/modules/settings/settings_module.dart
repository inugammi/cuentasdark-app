import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/db.dart';
import '../../core/module.dart';
import '../../core/settings.dart';
import '../../core/ui.dart';
import '../registry.dart';

class SettingsModule extends AppModule {
  @override
  String get id => 'settings';
  @override
  String get title => 'Ajustes';
  @override
  IconData get icon => Icons.settings;
  @override
  bool get optional => false;
  @override
  Widget build(BuildContext context) => const SettingsPage();
}

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Settings>();
    Future<void> numero(String k, String titulo, double actual) async {
      final t = await askText(context, titulo, initial: '$actual', type: const TextInputType.numberWithOptions(decimal: true));
      final v = double.tryParse(t ?? '');
      if (v != null) await s.set(k, v);
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Ajustes')),
      body: ListView(children: [
        const SectionTitle('Cuentas (como en tus Excel)'),
        ListTile(
          title: const Text('Cargo extra por recarga'),
          subtitle: Text('${money(s.cargoRecarga)} por recarga (Total día + Núm. rec.)'),
          onTap: () => numero('cargoRecarga', 'Cargo por recarga', s.cargoRecarga),
        ),
        ListTile(
          title: const Text('Bono al abonar saldo'),
          subtitle: Text('${s.bonoAbono}% (ganancia de recargas)'),
          onTap: () => numero('bonoAbono', 'Bono en %', s.bonoAbono),
        ),
        SwitchListTile(
          title: const Text('Diferencia = Venta − Total PDV + Recargas'),
          subtitle: const Text('Como tu hoja 2026. Apágalo para Venta − Total PDV.'),
          value: s.diferenciaConRecargas,
          onChanged: (v) => s.set('diferenciaConRecargas', v),
        ),
        const SectionTitle('TAE Pocket'),
        ListTile(
          title: const Text('Página de inicio'),
          subtitle: Text(s.taeUrl),
          onTap: () async {
            final t = await askText(context, 'Página de TAE Pocket', initial: s.taeUrl);
            if (t != null && t.startsWith('http')) await s.set('taeUrl', t);
          },
        ),
        ListTile(
          title: const Text('Página que se lee cada día'),
          subtitle: Text(s.taeHistorial.isEmpty ? 'Ninguna: en Recargas > 🌐 abre el historial y elige "Usar esta página"' : s.taeHistorial),
        ),
        SwitchListTile(
          title: const Text('Leer TAE Pocket al abrir la app'),
          subtitle: const Text('Una vez al día'),
          value: s.taeAuto,
          onChanged: (v) => s.set('taeAuto', v),
        ),
        const SectionTitle('Apariencia'),
        ListTile(
          title: const Text('Tema'),
          trailing: DropdownButton<String>(
            value: s.themeMode,
            items: const [
              DropdownMenuItem(value: 'dark', child: Text('Oscuro')),
              DropdownMenuItem(value: 'light', child: Text('Claro')),
              DropdownMenuItem(value: 'system', child: Text('Como el teléfono')),
            ],
            onChanged: (v) => s.set('themeMode', v!),
          ),
        ),
        SwitchListTile(title: const Text('Negro puro (AMOLED)'), value: s.amoled, onChanged: (v) => s.set('amoled', v)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(spacing: 8, children: [
            for (final p in palettes.entries)
              ChoiceChip(
                label: Text(p.key),
                avatar: CircleAvatar(backgroundColor: p.value),
                selected: s.seed == p.value.toARGB32(),
                onSelected: (_) => s.set('seed', p.value.toARGB32()),
              ),
          ]),
        ),
        ListTile(
          title: const Text('Tamaño de letra'),
          subtitle: Slider(
              value: s.textScale, min: 0.8, max: 1.4, divisions: 6, label: '${s.textScale}', onChanged: (v) => s.set('textScale', v)),
        ),
        const SectionTitle('Módulos'),
        for (final m in modules.where((m) => m.optional))
          SwitchListTile(
            secondary: Icon(m.icon),
            title: Text(m.title),
            value: !s.disabledModules.contains(m.id),
            onChanged: (v) {
              final l = [...s.disabledModules];
              v ? l.remove(m.id) : l.add(m.id);
              s.set('disabledModules', l);
            },
          ),
        const SectionTitle('Datos'),
        ListTile(
          leading: const Icon(Icons.history),
          title: const Text('Volver a cargar el histórico de los Excel'),
          subtitle: const Text('Solo agrega lo que falte; no borra lo que capturaste.'),
          onTap: () async {
            await Db.raw.delete('kv', where: 'k=?', whereArgs: ['historico']);
            final r = await Db.importarHistorico();
            avisarCambios();
            if (context.mounted) toast(context, r ?? 'Listo');
          },
        ),
      ]),
    );
  }
}
