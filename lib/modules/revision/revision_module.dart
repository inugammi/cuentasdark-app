import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/calc.dart';
import '../../core/db.dart';
import '../../core/module.dart';
import '../../core/revision.dart';
import '../../core/settings.dart';
import '../../core/ui.dart';
import '../clientes/clientes_module.dart';
import '../cuentas/dia_page.dart';

/// El vigilante: lo que no cuadra, lo que falta capturar y las recargas repetidas.
class RevisionModule extends AppModule {
  @override
  String get id => 'revision';
  @override
  String get title => 'Revisión';
  @override
  IconData get icon => Icons.fact_check;
  @override
  Widget build(BuildContext context) => const RevisionPage();
}

class RevisionPage extends StatefulWidget {
  const RevisionPage({super.key});
  @override
  State<RevisionPage> createState() => _RevisionPageState();
}

class _RevisionPageState extends State<RevisionPage> {
  List<Aviso>? avisos;
  var dias = 45;

  @override
  void initState() {
    super.initState();
    cambiosDatos.addListener(_cargar);
    _cargar();
  }

  @override
  void dispose() {
    cambiosDatos.removeListener(_cargar);
    super.dispose();
  }

  Future<void> _cargar() async {
    final a = await Vigilante.revisar(context.read<Settings>(), dias: dias);
    if (mounted) setState(() => avisos = a);
  }

  Future<void> _limpiar() async {
    final q = await Vigilante.limpiar();
    avisarCambios();
    if (mounted) toast(context, q == 0 ? 'No encontré recargas repetidas.' : 'Quité $q recargas repetidas.');
  }

  @override
  Widget build(BuildContext context) {
    final l = avisos;
    return Scaffold(
      appBar: AppBar(title: const Text('Revisión'), actions: [
        PopupMenuButton<int>(
          icon: const Icon(Icons.date_range),
          tooltip: 'Días a revisar',
          onSelected: (v) {
            dias = v;
            _cargar();
          },
          itemBuilder: (_) => [for (final d in [15, 45, 90, 365]) PopupMenuItem(value: d, child: Text('Últimos $d días'))],
        ),
      ]),
      body: l == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Wrap(spacing: 8, runSpacing: 8, children: [
                  FilledButton.icon(onPressed: _limpiar, icon: const Icon(Icons.cleaning_services), label: const Text('Buscar repetidas')),
                  OutlinedButton.icon(
                      onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const RepetidasPage())),
                      icon: const Icon(Icons.content_copy),
                      label: const Text('Ver repetidas')),
                ]),
              ),
              if (l.isEmpty) Empty(Icons.verified, 'Todo cuadra en los últimos $dias días. 👍'),
              for (final a in l)
                ListTile(
                  leading: Icon(
                    a.nivel == 2 ? Icons.error : (a.nivel == 1 ? Icons.warning_amber : Icons.info_outline),
                    color: a.nivel == 2 ? Colors.red : (a.nivel == 1 ? Colors.orange : Colors.blue),
                  ),
                  title: Text(a.titulo),
                  subtitle: Text(a.detalle),
                  onTap: a.fecha != null
                      ? () => Navigator.push(context, MaterialPageRoute(builder: (_) => DiaPage(fecha: a.fecha!))).then((_) => _cargar())
                      : a.telefono != null
                          ? () => Navigator.push(context, MaterialPageRoute(builder: (_) => ClientePage(telefono: a.telefono!)))
                              .then((_) => _cargar())
                          : null,
                ),
            ]),
    );
  }
}

/// Recargas que el vigilante quitó por repetidas, con la que se quedó al lado. Se pueden restaurar.
class RepetidasPage extends StatefulWidget {
  const RepetidasPage({super.key});
  @override
  State<RepetidasPage> createState() => _RepetidasPageState();
}

class _RepetidasPageState extends State<RepetidasPage> {
  List<Rec> lista = [];

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    final l = await Db.raw.rawQuery(
        "SELECT r.*, n.nombre FROM recargas r LEFT JOIN nombres n ON n.telefono=r.telefono AND n.deleted=0 "
        "WHERE r.origen='duplicado' ORDER BY r.fecha DESC LIMIT 500");
    if (mounted) setState(() => lista = l);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text('Repetidas quitadas (${lista.length})')),
        body: lista.isEmpty
            ? const Empty(Icons.verified, 'No hay recargas repetidas.')
            : ListView(children: [
                for (final r in lista)
                  ListTile(
                    title: Text('${r['nombre'] ?? r['telefono']} · ${money(n(r['monto']))}'),
                    subtitle: Text('${r['fecha']} · ${r['compania']} · folio ${r['folio'] ?? '—'}'),
                    trailing: TextButton(
                      child: const Text('Restaurar'),
                      onPressed: () async {
                        await Db.restaurarRecarga(r['clave'] as String);
                        avisarCambios();
                        _cargar();
                      },
                    ),
                  ),
              ]),
      );
}
