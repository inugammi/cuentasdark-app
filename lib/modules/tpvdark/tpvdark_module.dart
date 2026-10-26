import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/db.dart';
import '../../core/module.dart';
import '../../core/settings.dart';
import '../../core/tpv.dart';
import '../../core/ui.dart';
import 'sql.dart';

/// Conexión con TPVDark (Supabase): ventas del día, artículos, recargas de la caja y respaldo.
class TpvdarkModule extends AppModule {
  @override
  String get id => 'tpvdark';
  @override
  String get title => 'TPVDark';
  @override
  IconData get icon => Icons.cloud_sync;
  @override
  bool get optional => false;
  @override
  Widget build(BuildContext context) => const TpvdarkPage();
}

class TpvdarkPage extends StatefulWidget {
  const TpvdarkPage({super.key});
  @override
  State<TpvdarkPage> createState() => _TpvdarkPageState();
}

class _TpvdarkPageState extends State<TpvdarkPage> {
  late final Settings s = context.read<Settings>();
  late final url = TextEditingController(text: s.sbUrl);
  late final key = TextEditingController(text: s.sbKey);
  late final email = TextEditingController(text: s.sbEmail);
  late final pass = TextEditingController(text: s.sbPass);
  var trabajando = false;
  var log = '';
  String? ultima;

  @override
  void initState() {
    super.initState();
    Db.kv('tpvUltima').then((v) => setState(() => ultima = v));
  }

  Future<void> _guardar() async {
    await s.set('sbUrl', url.text.trim());
    await s.set('sbKey', key.text.trim());
    await s.set('sbEmail', email.text.trim());
    await s.set('sbPass', pass.text);
  }

  Future<void> _hacer(Future<String> Function(Tpv t) f) async {
    await _guardar();
    setState(() => trabajando = true);
    try {
      final r = await f(Tpv(s));
      log = r;
      avisarCambios();
    } catch (e) {
      log = '⚠ $e';
    }
    ultima = await Db.kv('tpvUltima');
    if (mounted) setState(() => trabajando = false);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('TPVDark')),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          const Text('Usa la MISMA cuenta de Supabase que TPVDark y TPVDarkMovil '
              '(en TPVDark: Diagnóstico > Supabase). La app trae sola cada día las ventas, '
              'los artículos vendidos y las recargas cobradas en la caja.'),
          const SizedBox(height: 12),
          TextField(controller: url, decoration: const InputDecoration(labelText: 'URL del proyecto (https://xxxx.supabase.co)')),
          const SizedBox(height: 8),
          TextField(controller: key, decoration: const InputDecoration(labelText: 'anon key')),
          const SizedBox(height: 8),
          TextField(controller: email, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: 'Correo')),
          const SizedBox(height: 8),
          TextField(controller: pass, obscureText: true, decoration: const InputDecoration(labelText: 'Contraseña')),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            OutlinedButton.icon(
                onPressed: trabajando ? null : () => _hacer((t) => t.probar()),
                icon: const Icon(Icons.wifi_tethering),
                label: const Text('Probar')),
            FilledButton.icon(
                onPressed: trabajando ? null : () => _hacer((t) => t.sincronizar()),
                icon: const Icon(Icons.sync),
                label: const Text('Traer ahora')),
            OutlinedButton.icon(
                onPressed: trabajando ? null : () => _hacer((t) => t.respaldar()),
                icon: const Icon(Icons.backup),
                label: const Text('Respaldar cuentas')),
          ]),
          if (trabajando) const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator()),
          if (log.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 12), child: SelectableText(log)),
          if (ultima != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text('Última vez: $ultima')),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Traer de TPVDark al abrir la app'),
            value: context.watch<Settings>().autoSync,
            onChanged: (v) => s.set('autoSync', v),
          ),
          const Divider(),
          const SectionTitle('Instalar en Supabase (una sola vez)'),
          const Text('Supabase > SQL Editor > New query > pega el SQL > RUN. Crea las vistas de ventas y artículos por día '
              'y las tablas del respaldo. No cambia nada de TPVDark.'),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
                onPressed: () {
                  Clipboard.setData(const ClipboardData(text: cuentasSql));
                  toast(context, 'SQL copiado.');
                },
                icon: const Icon(Icons.copy),
                label: const Text('Copiar SQL de instalación')),
          ),
        ]),
      );
}
