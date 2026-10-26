import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/calc.dart';
import '../../core/charts.dart';
import '../../core/db.dart';
import '../../core/module.dart';
import '../../core/settings.dart';
import '../../core/ui.dart';

/// Gráficas como las de Control Ciber: venta por mes de cada año, por día, por año y recargas.
class GraficasModule extends AppModule {
  @override
  String get id => 'graficas';
  @override
  String get title => 'Gráficas';
  @override
  IconData get icon => Icons.show_chart;
  @override
  Widget build(BuildContext context) => const GraficasPage();
}

class GraficasPage extends StatefulWidget {
  const GraficasPage({super.key});
  @override
  State<GraficasPage> createState() => _GraficasPageState();
}

const _mesesCortos = ['Ene', 'Feb', 'Mar', 'Abr', 'May', 'Jun', 'Jul', 'Ago', 'Sep', 'Oct', 'Nov', 'Dic'];

class _GraficasPageState extends State<GraficasPage> {
  Map<int, List<double?>> ventaMes = {}; // año -> 12 meses
  Map<int, List<double?>> recargaMes = {};
  Map<int, List<double?>> gastoMes = {};
  Set<int> anios = {};
  var mes = DateTime(DateTime.now().year, DateTime.now().month);
  List<double> ventaDias = [];

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

  Future<Map<int, List<double?>>> _porMes(String sql) async {
    final out = <int, List<double?>>{};
    for (final r in await Db.raw.rawQuery(sql)) {
      final y = int.parse(r['m'] as String);
      final m = int.parse((r['mm'] as String));
      out.putIfAbsent(y, () => List<double?>.filled(12, null))[m - 1] = n(r['t']);
    }
    return out;
  }

  Future<void> _cargar() async {
    final v = await _porMes(
        "SELECT substr(fecha,1,4) m, substr(fecha,6,2) mm, SUM(venta) t FROM dias WHERE deleted=0 GROUP BY 1,2 HAVING SUM(venta)<>0");
    final r = await _porMes(
        "SELECT substr(fecha,1,4) m, substr(fecha,6,2) mm, SUM(monto) t FROM recargas WHERE deleted=0 GROUP BY 1,2");
    final g = await _porMes(
        "SELECT substr(fecha,1,4) m, substr(fecha,6,2) mm, SUM(IFNULL(gastos,0)+IFNULL(pagos,0)) t FROM dias WHERE deleted=0 GROUP BY 1,2 HAVING t<>0");
    final ys = v.keys.toList()..sort();
    if (!mounted) return;
    setState(() {
      ventaMes = v;
      recargaMes = r;
      gastoMes = g;
      if (anios.isEmpty) anios = ys.reversed.take(4).toSet();
    });
    _cargarMes();
  }

  Future<void> _cargarMes() async {
    final f = DateTime(mes.year, mes.month + 1);
    final d = {for (final x in await Db.dias(iso(mes), iso(f))) x['fecha'] as String: n(x['venta'])};
    final total = f.subtract(const Duration(days: 1)).day;
    if (mounted) setState(() => ventaDias = [for (var i = 1; i <= total; i++) d[iso(DateTime(mes.year, mes.month, i))] ?? 0]);
  }

  @override
  Widget build(BuildContext context) {
    final todos = ventaMes.keys.toList()..sort();
    final elegidos = todos.where(anios.contains).toList();
    final porAnio = [for (final y in todos) ventaMes[y]!.fold(0.0, (a, b) => a + (b ?? 0))];
    final anioRec = recargaMes.keys.toList()..sort();
    final yr = anioRec.isEmpty ? DateTime.now().year : anioRec.last;
    return Scaffold(
      appBar: AppBar(title: const Text('Gráficas')),
      body: ListView(children: [
        const SectionTitle('Venta por mes (compara años)'),
        SizedBox(
          height: 48,
          child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 8), children: [
            for (final y in todos.reversed)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: FilterChip(
                    label: Text('$y'),
                    selected: anios.contains(y),
                    onSelected: (v) => setState(() => v ? anios.add(y) : anios.remove(y))),
              ),
          ]),
        ),
        if (elegidos.isEmpty)
          const Empty(Icons.show_chart, 'Elige uno o más años.')
        else
          Lineas(_mesesCortos, {for (final y in elegidos) '$y': ventaMes[y]!}),
        if (elegidos.isNotEmpty)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Table(columnWidths: const {0: FixedColumnWidth(48)}, children: [
              TableRow(children: [
                const Text(''),
                for (final y in elegidos) Text('$y', textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.bold)),
              ]),
              for (var m = 0; m < 12; m++)
                TableRow(children: [
                  Text(_mesesCortos[m]),
                  for (final y in elegidos)
                    Text(ventaMes[y]![m] == null ? '—' : money(ventaMes[y]![m]!.roundToDouble()), textAlign: TextAlign.right),
                ]),
              TableRow(children: [
                const Text('Total', style: TextStyle(fontWeight: FontWeight.bold)),
                for (final y in elegidos)
                  Text(money(ventaMes[y]!.fold(0.0, (a, b) => a + (b ?? 0)).roundToDouble()),
                      textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.bold)),
              ]),
            ]),
          ),
        const SectionTitle('Venta por día'),
        Row(children: [
          IconButton(
              icon: const Icon(Icons.chevron_left),
              onPressed: () {
                mes = DateTime(mes.year, mes.month - 1);
                _cargarMes();
              }),
          Expanded(child: Text(DateFormat('MMMM yyyy', 'es').format(mes), textAlign: TextAlign.center)),
          IconButton(
              icon: const Icon(Icons.chevron_right),
              onPressed: () {
                mes = DateTime(mes.year, mes.month + 1);
                _cargarMes();
              }),
        ]),
        Barras([for (var i = 1; i <= ventaDias.length; i++) '$i'], ventaDias, color: Colors.green),
        const SectionTitle('Venta por año'),
        Barras([for (final y in todos) "'${'$y'.substring(2)}"], porAnio, color: Colors.teal),
        SectionTitle('Recargas por mes $yr'),
        if (recargaMes[yr] != null) Barras(_mesesCortos, [for (final v in recargaMes[yr]!) v ?? 0], color: Colors.orange),
        if (gastoMes[DateTime.now().year] != null) ...[
          SectionTitle('Gastos + pagos por mes ${DateTime.now().year}'),
          Barras(_mesesCortos, [for (final v in gastoMes[DateTime.now().year]!) v ?? 0], color: Colors.red),
        ],
        const SizedBox(height: 32),
      ]),
    );
  }
}
