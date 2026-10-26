import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/calc.dart';
import '../../core/charts.dart';
import '../../core/db.dart';
import '../../core/module.dart';
import '../../core/settings.dart';
import '../../core/ui.dart';

/// Quién recarga: la hoja NOMBRES de tus Excel, con cuántas veces y cuánto recargó cada número.
class ClientesModule extends AppModule {
  @override
  String get id => 'clientes';
  @override
  String get title => 'Clientes';
  @override
  IconData get icon => Icons.people;
  @override
  Widget build(BuildContext context) => const ClientesPage();
}

class ClientesPage extends StatefulWidget {
  const ClientesPage({super.key});
  @override
  State<ClientesPage> createState() => _ClientesPageState();
}

class _ClientesPageState extends State<ClientesPage> {
  var periodo = Periodo.mes;
  var ini = inicio(Periodo.mes, DateTime.now());
  var todo = false;
  var buscar = '';
  var orden = 'veces';
  List<Rec> filas = [];

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
    final b = '%${buscar.trim()}%';
    final r = await Db.raw.rawQuery(
        'SELECT r.telefono, n.nombre, COUNT(*) veces, SUM(r.monto) total, MAX(r.fecha) ultima '
        'FROM recargas r LEFT JOIN nombres n ON n.telefono=r.telefono AND n.deleted=0 '
        'WHERE r.deleted=0 ${todo ? '' : 'AND r.fecha>=? AND r.fecha<?'} '
        'AND (r.telefono LIKE ? OR IFNULL(n.nombre,\'\') LIKE ?) '
        'GROUP BY r.telefono ORDER BY ${orden == 'veces' ? 'veces' : orden == 'total' ? 'total' : 'ultima'} DESC LIMIT 400',
        [if (!todo) iso(ini), if (!todo) iso(fin(periodo, ini)), b, b]);
    if (mounted) setState(() => filas = r);
  }

  @override
  Widget build(BuildContext context) {
    final conNombre = filas.where((f) => f['nombre'] != null).length;
    return Scaffold(
      appBar: AppBar(title: const Text('Quién recarga'), actions: [
        PopupMenuButton<String>(
          icon: const Icon(Icons.sort),
          onSelected: (v) {
            orden = v;
            _cargar();
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'veces', child: Text('Más recargas')),
            PopupMenuItem(value: 'total', child: Text('Más dinero')),
            PopupMenuItem(value: 'ultima', child: Text('Más recientes')),
          ],
        ),
      ]),
      body: ListView(children: [
        if (!todo)
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
        SwitchListTile(
            dense: true,
            title: const Text('Ver todos los años'),
            value: todo,
            onChanged: (v) {
              setState(() => todo = v);
              _cargar();
            }),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TextField(
            decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Nombre o número'),
            onChanged: (v) {
              buscar = v;
              _cargar();
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text('${filas.length} números · $conNombre con nombre', style: Theme.of(context).textTheme.bodySmall),
        ),
        for (final f in filas)
          ListTile(
            leading: CircleAvatar(child: Text('${f['veces']}')),
            title: Text(f['nombre'] as String? ?? 'Sin nombre',
                style: f['nombre'] == null ? TextStyle(color: Theme.of(context).colorScheme.outline) : null),
            subtitle: Text('${f['telefono']} · última ${(f['ultima'] as String).substring(0, 10)}'),
            trailing: Text(money(n(f['total'])), style: const TextStyle(fontWeight: FontWeight.bold)),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ClientePage(telefono: f['telefono'] as String)))
                .then((_) => _cargar()),
          ),
      ]),
    );
  }
}

/// Historial de un número: nombre (editable), recargas por mes y lista completa.
class ClientePage extends StatefulWidget {
  final String telefono;
  const ClientePage({super.key, required this.telefono});
  @override
  State<ClientePage> createState() => _ClientePageState();
}

class _ClientePageState extends State<ClientePage> {
  String? nombre;
  List<Rec> lista = [];

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    final nm = await Db.raw.query('nombres', where: 'telefono=? AND deleted=0', whereArgs: [widget.telefono]);
    final l = await Db.recargas('0000', '9999', tel: widget.telefono);
    if (!mounted) return;
    setState(() {
      nombre = nm.isEmpty ? null : nm.first['nombre'] as String?;
      lista = l;
    });
  }

  Future<void> _nombre() async {
    final t = await askText(context, 'Nombre de ${widget.telefono}', initial: nombre ?? '', hint: 'Ej. Yessi maestra');
    if (t == null) return;
    await Db.guardarNombre(widget.telefono, t);
    avisarCambios();
    _cargar();
  }

  @override
  Widget build(BuildContext context) {
    final total = lista.fold(0.0, (a, r) => a + n(r['monto']));
    final meses = <String, double>{};
    for (final r in lista) {
      final m = (r['fecha'] as String).substring(0, 7);
      meses[m] = (meses[m] ?? 0) + n(r['monto']);
    }
    final ult = meses.keys.toList()..sort();
    final ultimos = ult.length > 12 ? ult.sublist(ult.length - 12) : ult;
    return Scaffold(
      appBar: AppBar(title: Text(nombre ?? widget.telefono), actions: [
        IconButton(icon: const Icon(Icons.edit), tooltip: 'Poner nombre', onPressed: _nombre),
      ]),
      body: ListView(children: [
        ListTile(
          leading: const Icon(Icons.person),
          title: Text(nombre ?? 'Sin nombre (toca para ponerlo)'),
          subtitle: Text(widget.telefono),
          onTap: _nombre,
        ),
        Datos([
          Dato('Recargas', entero(lista.length)),
          Dato('Total', money(total), color: Colors.green),
          Dato('Promedio', money(lista.isEmpty ? 0 : total / lista.length)),
        ]),
        if (ultimos.length > 1) ...[
          const SectionTitle('Últimos meses'),
          Barras([for (final m in ultimos) DateFormat('MMM yy', 'es').format(DateTime.parse('$m-01'))],
              [for (final m in ultimos) meses[m]!]),
        ],
        const SectionTitle('Historial'),
        for (final r in lista)
          ListTile(
            dense: true,
            title: Text('${r['fecha']}'),
            subtitle: Text('${r['compania']} · ${r['proveedor']}'),
            trailing: Text(money(n(r['monto']))),
          ),
      ]),
    );
  }
}
