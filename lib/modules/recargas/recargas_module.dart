import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/calc.dart';
import '../../core/db.dart';
import '../../core/module.dart';
import '../../core/settings.dart';
import '../../core/tae.dart';
import '../../core/ui.dart';
import '../clientes/clientes_module.dart';

/// Lo de los Excel TAEPOCKET / RECARGAS: cada recarga, total por día, por compañía y abonos de saldo.
class RecargasModule extends AppModule {
  @override
  String get id => 'recargas';
  @override
  String get title => 'Recargas';
  @override
  IconData get icon => Icons.phone_android;
  @override
  Widget build(BuildContext context) => const RecargasPage();
}

class RecargasPage extends StatefulWidget {
  const RecargasPage({super.key});
  @override
  State<RecargasPage> createState() => _RecargasPageState();
}

class _RecargasPageState extends State<RecargasPage> {
  var periodo = Periodo.dia;
  var ini = inicio(Periodo.dia, DateTime.now());
  List<Rec> lista = [];
  List<Rec> abonos = [];
  String? ultima;

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
    final f = fin(periodo, ini);
    final l = await Db.recargas(iso(ini), iso(f));
    final a = await Db.raw.query('abonos', where: 'deleted=0 AND fecha>=? AND fecha<?', whereArgs: [iso(ini), iso(f)], orderBy: 'fecha DESC');
    final u = await Db.raw.rawQuery('SELECT MAX(fecha) f FROM recargas WHERE deleted=0');
    if (!mounted) return;
    setState(() {
      lista = l;
      abonos = a;
      ultima = u.first['f'] as String?;
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Settings>();
    final total = lista.fold(0.0, (a, r) => a + n(r['monto']));
    final porCia = <String, (double, int)>{};
    for (final r in lista) {
      final c = (r['compania'] as String?)?.isNotEmpty == true ? r['compania'] as String : 'OTRA';
      final a = porCia[c] ?? (0.0, 0);
      porCia[c] = (a.$1 + n(r['monto']), a.$2 + 1);
    }
    final cias = porCia.entries.toList()..sort((a, b) => b.value.$1.compareTo(a.value.$1));
    final abonado = abonos.fold(0.0, (a, r) => a + n(r['monto']));
    return Scaffold(
      appBar: AppBar(title: const Text('Recargas'), actions: [
        IconButton(
            tooltip: 'TAE Pocket',
            icon: const Icon(Icons.public),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const TaePage()))),
        PopupMenuButton<String>(
          onSelected: (v) => switch (v) {
            'pegar' => _pegar(),
            'nueva' => _nueva(),
            'abono' => _abono(),
            _ => null,
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'pegar', child: Text('Pegar historial copiado')),
            PopupMenuItem(value: 'nueva', child: Text('Agregar recarga a mano')),
            PopupMenuItem(value: 'abono', child: Text('Registrar abono de saldo')),
          ],
        ),
      ]),
      body: ListView(children: [
        SelectorPeriodo(
            periodo: periodo,
            inicio: ini,
            cambio: (p, i) {
              setState(() {
                periodo = p;
                ini = i;
              });
              _cargar();
            }),
        if (ultima != null)
          Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text('Última recarga guardada: $ultima', style: Theme.of(context).textTheme.bodySmall)),
        Datos([
          Dato('Total', money(total), color: Colors.green),
          Dato('Recargas', entero(lista.length), sub: 'Cobrado ${money(total + s.cargoRecarga * lista.length)}'),
          Dato('Ganancia', money(total * s.bonoAbono / 100 + s.cargoRecarga * lista.length),
              sub: '${s.bonoAbono}% + ${money(s.cargoRecarga)} c/u'),
        ]),
        if (abonos.isNotEmpty)
          ExpansionTile(
            title: Text('Abonos de saldo: ${money(abonado)}'),
            subtitle: Text('Con bono ${s.bonoAbono}%: ${money(abonado * (1 + s.bonoAbono / 100))}'),
            children: [
              for (final a in abonos)
                ListTile(
                    dense: true,
                    title: Text(money(n(a['monto']))),
                    subtitle: Text('${a['fecha']} · ${a['proveedor'] ?? ''} ${a['notas'] ?? ''}'),
                    trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () async {
                          if (!await confirm(context, '¿Borrar este abono?')) return;
                          await Db.raw.update('abonos', {'deleted': 1, 'synced': 0, 'updated_at': Db.now},
                              where: 'id=?', whereArgs: [a['id']]);
                          _cargar();
                        })),
            ],
          ),
        if (cias.isNotEmpty) const SectionTitle('Por compañía'),
        for (final c in cias)
          ListTile(
            dense: true,
            title: Text(c.key),
            subtitle: LinearProgressIndicator(value: total == 0 ? 0 : c.value.$1 / total),
            trailing: Text('${money(c.value.$1)} (${c.value.$2})'),
          ),
        if (lista.isEmpty)
          const Empty(Icons.phone_android, 'No hay recargas en este periodo.\nToca 🌐 para leerlas de TAE Pocket.'),
        if (lista.isNotEmpty) SectionTitle('Recargas (${lista.length})'),
        for (final r in lista.take(500))
          ListTile(
            dense: true,
            leading: CircleAvatar(radius: 16, child: Text((r['compania'] as String? ?? '?').padRight(1).substring(0, 1))),
            title: Text(r['nombre'] as String? ?? r['telefono'] as String? ?? ''),
            subtitle: Text('${r['nombre'] != null ? '${r['telefono']} · ' : ''}${r['compania']} · '
                '${periodo == Periodo.dia ? (r['fecha'] as String).substring(11) : r['fecha']}'),
            trailing: Text(money(n(r['monto'])), style: const TextStyle(fontWeight: FontWeight.bold)),
            onTap: () => Navigator.push(
                context, MaterialPageRoute(builder: (_) => ClientePage(telefono: r['telefono'] as String))).then((_) => _cargar()),
            onLongPress: () async {
              if (!await confirm(context, '¿Borrar esta recarga de ${money(n(r['monto']))}?')) return;
              await Db.borrarRecarga(r['clave'] as String);
              avisarCambios();
            },
          ),
        if (lista.length > 500) const ListTile(title: Text('Se muestran las primeras 500.')),
        const SizedBox(height: 40),
      ]),
    );
  }

  Future<void> _pegar() async {
    final t = await askText(context, 'Pega el historial',
        hint: 'Copia la tabla de TAE Pocket (o de tu Excel) y pégala aquí', lines: 8, ok: 'Leer');
    if (t == null || t.isEmpty) return;
    final recs = pegarRecargas(t);
    final nuevas = await Db.guardarRecargas(recs, 'pegado');
    avisarCambios();
    if (mounted) toast(context, 'Leí ${recs.length} recargas: $nuevas nuevas.');
  }

  Future<void> _nueva() async {
    final tel = TextEditingController(), monto = TextEditingController(), cia = TextEditingController(text: 'TELCEL');
    var fecha = DateTime.now();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Recarga a mano'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: tel, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Número (10 dígitos)')),
          const SizedBox(height: 8),
          TextField(controller: monto, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Monto')),
          const SizedBox(height: 8),
          TextField(controller: cia, decoration: const InputDecoration(labelText: 'Compañía')),
          const SizedBox(height: 8),
          Text(DateFormat('d MMM yyyy HH:mm', 'es').format(fecha)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Guardar')),
        ],
      ),
    );
    final t = telefono(tel.text);
    if (ok != true || t == null || n(monto.text) <= 0) {
      if (ok == true && mounted) toast(context, 'Revisa el número (10 dígitos) y el monto.');
      return;
    }
    fecha = DateTime(fecha.year, fecha.month, fecha.day, fecha.hour, fecha.minute);
    await Db.guardarRecargas([
      {'fecha': fechaHora(fecha), 'compania': cia.text.trim().toUpperCase(), 'telefono': t, 'monto': n(monto.text),
       'folio': 'MANUAL-${Db.now}', 'proveedor': 'MANUAL'}
    ], 'manual');
    avisarCambios();
  }

  Future<void> _abono() async {
    final m = await askText(context, 'Abono de saldo a TAE Pocket', hint: 'Monto que depositaste', type: TextInputType.number);
    if (m == null || n(m) <= 0) return;
    final f = iso(periodo == Periodo.dia ? ini : DateTime.now());
    await Db.raw.insert('abonos',
        {'id': Db.newId(), 'fecha': f, 'monto': n(m), 'proveedor': 'TAEPOCKET', 'updated_at': Db.now, 'synced': 0, 'deleted': 0});
    _cargar();
  }
}
