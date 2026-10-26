import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/calc.dart';
import '../../core/charts.dart';
import '../../core/db.dart';
import '../../core/module.dart';
import '../../core/settings.dart';
import '../../core/tpv.dart';
import '../../core/ui.dart';

/// Histórico de artículos vendidos en TPVDark: cuánto se vendió por día, semana y mes.
class ArticulosModule extends AppModule {
  @override
  String get id => 'articulos';
  @override
  String get title => 'Artículos';
  @override
  IconData get icon => Icons.inventory_2;
  @override
  Widget build(BuildContext context) => const ArticulosPage();
}

class ArticulosPage extends StatefulWidget {
  const ArticulosPage({super.key});
  @override
  State<ArticulosPage> createState() => _ArticulosPageState();
}

class _ArticulosPageState extends State<ArticulosPage> {
  var periodo = Periodo.dia;
  var ini = inicio(Periodo.dia, DateTime.now());
  var buscar = '';
  var porDinero = false;
  var trayendo = false;
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
        'SELECT articulo, MAX(descripcion) descripcion, SUM(cantidad) cantidad, SUM(total) total, COUNT(DISTINCT fecha) dias '
        'FROM art_dia WHERE fecha>=? AND fecha<? AND (articulo LIKE ? OR descripcion LIKE ?) '
        'GROUP BY articulo ORDER BY ${porDinero ? 'total' : 'cantidad'} DESC LIMIT 500',
        [iso(ini), iso(fin(periodo, ini)), b, b]);
    if (mounted) setState(() => filas = r);
  }

  Future<void> _traer() async {
    final s = context.read<Settings>();
    final tpv = Tpv(s);
    if (!tpv.configurado) {
      toast(context, 'Primero conecta TPVDark en Más > TPVDark.');
      return;
    }
    setState(() => trayendo = true);
    try {
      final f = fin(periodo, ini);
      final hoy = soloFecha(DateTime.now()).add(const Duration(days: 1));
      final k = await tpv.articulos(ini, f.isAfter(hoy) ? hoy : f);
      if (mounted) toast(context, 'Listo: $k artículos/día.');
      avisarCambios();
    } catch (e) {
      if (mounted) toast(context, '$e');
    }
    if (mounted) setState(() => trayendo = false);
  }

  @override
  Widget build(BuildContext context) {
    final total = filas.fold(0.0, (a, r) => a + n(r['total']));
    final piezas = filas.fold(0.0, (a, r) => a + n(r['cantidad']));
    return Scaffold(
      appBar: AppBar(title: const Text('Artículos vendidos'), actions: [
        IconButton(
            tooltip: porDinero ? 'Ordenar por piezas' : 'Ordenar por dinero',
            icon: Icon(porDinero ? Icons.attach_money : Icons.numbers),
            onPressed: () {
              porDinero = !porDinero;
              _cargar();
            }),
        IconButton(
            tooltip: 'Traer de TPVDark este periodo',
            icon: trayendo ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.sync),
            onPressed: trayendo ? null : _traer),
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
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TextField(
            decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Buscar artículo'),
            onChanged: (v) {
              buscar = v;
              _cargar();
            },
          ),
        ),
        Datos([
          Dato('Vendido', money(total), color: Colors.green),
          Dato('Piezas', entero(piezas)),
          Dato('Artículos', entero(filas.length)),
        ]),
        if (filas.isEmpty)
          const Empty(Icons.inventory_2, 'No hay ventas de artículos en este periodo.\nToca ⟳ para traerlas de TPVDark.'),
        for (final (i, f) in filas.indexed)
          ListTile(
            dense: true,
            leading: CircleAvatar(radius: 16, child: Text('${i + 1}', style: const TextStyle(fontSize: 12))),
            title: Text(f['descripcion'] as String? ?? f['articulo'] as String),
            subtitle: Text('${f['articulo']} · ${n(f['cantidad']) % 1 == 0 ? n(f['cantidad']).toInt() : n(f['cantidad']).toStringAsFixed(2)} pzas'
                '${periodo != Periodo.dia ? ' · ${f['dias']} días' : ''}'),
            trailing: Text(money(n(f['total'])), style: const TextStyle(fontWeight: FontWeight.bold)),
            onTap: () => Navigator.push(
                context, MaterialPageRoute(builder: (_) => ArticuloPage(articulo: f['articulo'] as String, nombre: '${f['descripcion']}'))),
          ),
      ]),
    );
  }
}

/// Un artículo: piezas por día (últimos 30), por semana (últimas 12) y por mes.
class ArticuloPage extends StatefulWidget {
  final String articulo, nombre;
  const ArticuloPage({super.key, required this.articulo, required this.nombre});
  @override
  State<ArticuloPage> createState() => _ArticuloPageState();
}

class _ArticuloPageState extends State<ArticuloPage> {
  Map<String, (double, double)> dias = {};

  @override
  void initState() {
    super.initState();
    Db.raw.query('art_dia', where: 'articulo=?', whereArgs: [widget.articulo]).then((r) {
      if (mounted) setState(() => dias = {for (final x in r) x['fecha'] as String: (n(x['cantidad']), n(x['total']))});
    });
  }

  @override
  Widget build(BuildContext context) {
    final hoy = soloFecha(DateTime.now());
    final d30 = [for (var i = 29; i >= 0; i--) hoy.subtract(Duration(days: i))];
    final sem = [for (var i = 11; i >= 0; i--) inicio(Periodo.semana, hoy).subtract(Duration(days: 7 * i))];
    final meses = <String, double>{};
    for (final e in dias.entries) {
      meses[e.key.substring(0, 7)] = (meses[e.key.substring(0, 7)] ?? 0) + e.value.$1;
    }
    final mk = meses.keys.toList()..sort();
    double semana(DateTime i) {
      var t = 0.0;
      for (var k = 0; k < 7; k++) {
        t += dias[iso(i.add(Duration(days: k)))]?.$1 ?? 0;
      }
      return t;
    }

    final tot = dias.values.fold(0.0, (a, b) => a + b.$1);
    final din = dias.values.fold(0.0, (a, b) => a + b.$2);
    return Scaffold(
      appBar: AppBar(title: Text(widget.nombre)),
      body: ListView(children: [
        Datos([
          Dato('Piezas', entero(tot)),
          Dato('Vendido', money(din), color: Colors.green),
          Dato('Por día', (dias.isEmpty ? 0 : tot / dias.length).toStringAsFixed(1), sub: 'en días con venta'),
        ]),
        const SectionTitle('Piezas por día (30 días)'),
        Barras([for (final d in d30) '${d.day}'], [for (final d in d30) dias[iso(d)]?.$1 ?? 0], formato: _pzas),
        const SectionTitle('Piezas por semana'),
        Barras([for (final s in sem) DateFormat('d/M').format(s)], [for (final s in sem) semana(s)], formato: _pzas),
        if (mk.isNotEmpty) ...[
          const SectionTitle('Piezas por mes'),
          Barras([for (final m in mk) DateFormat('MMM yy', 'es').format(DateTime.parse('$m-01'))], [for (final m in mk) meses[m]!], formato: _pzas),
        ],
        const SizedBox(height: 24),
      ]),
    );
  }
}

String _pzas(double v) => '${v % 1 == 0 ? v.toInt() : v.toStringAsFixed(2)} pzas';
