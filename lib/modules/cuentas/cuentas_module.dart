import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/calc.dart';
import '../../core/db.dart';
import '../../core/module.dart';
import '../../core/settings.dart';
import '../../core/ui.dart';
import '../revision/revision_module.dart';
import '../../core/revision.dart';
import 'dia_page.dart';

/// Lo de la hoja de Control Ciber: venta de cada día, por semana, mes y año.
class CuentasModule extends AppModule {
  @override
  String get id => 'cuentas';
  @override
  String get title => 'Cuentas';
  @override
  IconData get icon => Icons.point_of_sale;
  @override
  bool get optional => false;
  @override
  Widget build(BuildContext context) => const CuentasPage();
}

/// Resumen de un grupo de días.
class Suma {
  double venta = 0, gastos = 0, pagos = 0, ingresos = 0, recargas = 0, pdv = 0, dif = 0;
  int dias = 0;
  void add(Rec d, Settings s) {
    venta += n(d['venta']);
    gastos += n(d['gastos']);
    pagos += n(d['pagos']);
    ingresos += n(d['ingresos']) + n(d['otros_ingresos']);
    recargas += n(d['recargas']);
    pdv += n(d['total_pdv']);
    if (d['total_pdv'] != null) dif += diferencia(d, sumarRecargas: s.diferenciaConRecargas);
    if (n(d['venta']) != 0) dias++;
  }
}

class CuentasPage extends StatefulWidget {
  const CuentasPage({super.key});
  @override
  State<CuentasPage> createState() => _CuentasPageState();
}

class _CuentasPageState extends State<CuentasPage> {
  var periodo = Periodo.mes;
  var ini = inicio(Periodo.mes, DateTime.now());
  List<Rec> dias = [];
  Map<String, double> tpv = {};
  String? aviso;
  int pendientes = 0;

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
    final d = await Db.dias(iso(ini), iso(f));
    final t = await Db.raw.query('tpv_dia', where: 'fecha>=? AND fecha<?', whereArgs: [iso(ini), iso(f)]);
    final a = await Db.kv('taeAviso');
    if (!mounted) return;
    final rev = await Vigilante.revisar(context.read<Settings>(), dias: 15);
    if (!mounted) return;
    pendientes = rev.where((x) => x.nivel > 0).length;
    setState(() {
      dias = d;
      tpv = {for (final x in t) x['fecha'] as String: n(x['ventas'])};
      aviso = a;
    });
  }

  Future<void> _abrir(DateTime d) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => DiaPage(fecha: iso(d))));
    _cargar();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Settings>();
    final total = Suma();
    for (final d in dias) {
      total.add(d, s);
    }
    final porFecha = {for (final d in dias) d['fecha'] as String: d};
    return Scaffold(
      appBar: AppBar(title: const Text('Cuentas del día')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _abrir(DateTime.now()),
        icon: const Icon(Icons.edit_calendar),
        label: const Text('Capturar hoy'),
      ),
      body: ListView(padding: const EdgeInsets.only(bottom: 88), children: [
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
        if (pendientes > 0)
          Card(
            color: Theme.of(context).colorScheme.errorContainer,
            margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
            child: ListTile(
              leading: const Icon(Icons.fact_check),
              title: Text('$pendientes cosas por revisar'),
              subtitle: const Text('Días sin capturar, diferencias o lecturas pendientes'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const RevisionPage())).then((_) => _cargar()),
            ),
          ),
        if (aviso != null && periodo != Periodo.anio)
          Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(aviso!, style: Theme.of(context).textTheme.bodySmall)),
        Datos([
          Dato('Venta', money(total.venta), color: Colors.green, sub: total.dias > 1 ? 'Promedio ${money(total.venta / total.dias)}' : null),
          Dato('Gastos', money(total.gastos), color: Colors.red),
          Dato('Pagos', money(total.pagos), color: Colors.orange),
          Dato('Recargas', money(total.recargas)),
          Dato('Ingresos', money(total.ingresos)),
          Dato('Total PDV', money(total.pdv), sub: total.pdv != 0 ? 'Diferencia ${money(total.dif)}' : null),
        ]),
        if (periodo == Periodo.dia) _detalleDia(porFecha[iso(ini)], s),
        if (periodo == Periodo.semana || periodo == Periodo.mes) ..._listaDias(porFecha),
        if (periodo == Periodo.anio) ..._listaMeses(s),
      ]),
    );
  }

  Widget _detalleDia(Rec? d, Settings s) {
    if (d == null) {
      return ListTile(
          leading: const Icon(Icons.add),
          title: const Text('Este día no está capturado'),
          trailing: FilledButton(onPressed: () => _abrir(ini), child: const Text('Capturar')),
          subtitle: tpv[iso(ini)] != null ? Text('TPVDark vendió ${money(tpv[iso(ini)]!)}') : null);
    }
    Widget fila(String a, Object? v, {String? txt}) => ListTile(
        dense: true, title: Text(a), subtitle: txt != null && txt.isNotEmpty ? Text(txt) : null, trailing: Text(money(n(v))));
    return Column(children: [
      fila('Billetes', billetes(d)),
      fila('Sencillo', d['sencillo']),
      fila('Ingresos', d['ingresos'], txt: d['ingresos_txt'] as String?),
      fila('Gastos', d['gastos'], txt: d['gastos_txt'] as String?),
      fila('Pagos', d['pagos'], txt: d['pagos_txt'] as String?),
      fila('Caja', d['caja']),
      fila('Cambio', d['cambio']),
      fila('Gasto banca', d['gasto_banca'], txt: d['gasto_banca_txt'] as String?),
      fila('Banca', d['banca']),
      fila('Sencillo total', d['sencillo_total']),
      fila('Total global', totalGlobal(d)),
      fila('Total PDV', d['total_pdv'] ?? tpv[iso(ini)]),
      if (d['notas'] != null) ListTile(dense: true, title: Text('${d['notas']}')),
      Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton.icon(onPressed: () => _abrir(ini), icon: const Icon(Icons.edit), label: const Text('Editar día'))),
    ]);
  }

  List<Widget> _listaDias(Map<String, Rec> porFecha) {
    final f = fin(periodo, ini);
    final hoy = soloFecha(DateTime.now());
    final out = <Widget>[];
    for (var d = ini; d.isBefore(f) && !d.isAfter(hoy); d = DateTime(d.year, d.month, d.day + 1)) {
      final x = porFecha[iso(d)];
      final pdv = x?['total_pdv'] ?? tpv[iso(d)];
      out.add(ListTile(
        dense: true,
        leading: CircleAvatar(radius: 16, child: Text('${d.day}')),
        title: Text(DateFormat('EEEE', 'es').format(d)),
        subtitle: x == null
            ? Text(pdv != null ? 'Sin capturar · PDV ${money(n(pdv))}' : 'Sin capturar')
            : Text('Gastos ${money(n(x['gastos']))} · Pagos ${money(n(x['pagos']))}${pdv != null ? ' · PDV ${money(n(pdv))}' : ''}'),
        trailing: Text(x == null ? '—' : money(n(x['venta'])),
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
        onTap: () => _abrir(d),
      ));
      if (periodo == Periodo.mes && d.weekday == DateTime.sunday) {
        var sem = 0.0;
        for (var k = 0; k < 7; k++) {
          sem += n(porFecha[iso(d.subtract(Duration(days: k)))]?['venta']);
        }
        out.add(Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text('Semana: ${money(sem)}',
              textAlign: TextAlign.right, style: TextStyle(color: Theme.of(context).colorScheme.primary)),
        ));
      }
    }
    return out.reversed.toList();
  }

  List<Widget> _listaMeses(Settings s) {
    final meses = List.generate(12, (_) => Suma());
    for (final d in dias) {
      meses[int.parse((d['fecha'] as String).substring(5, 7)) - 1].add(d, s);
    }
    return [
      for (var m = 0; m < 12; m++)
        if (meses[m].dias > 0)
          ListTile(
            title: Text(toBeginningOfSentenceCase(DateFormat('MMMM', 'es').format(DateTime(ini.year, m + 1)))),
            subtitle: Text('Gastos ${money(meses[m].gastos)} · Pagos ${money(meses[m].pagos)} · Recargas ${money(meses[m].recargas)}'),
            trailing: Text(money(meses[m].venta), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
            onTap: () {
              setState(() {
                periodo = Periodo.mes;
                ini = DateTime(ini.year, m + 1);
              });
              _cargar();
            },
          ),
    ];
  }
}
