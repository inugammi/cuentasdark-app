import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/calc.dart';
import '../../core/db.dart';
import '../../core/module.dart';
import '../../core/settings.dart';
import '../../core/ui.dart';

/// Captura o corrige un día, igual que un renglón de Control Ciber.
/// Los textos de ingresos/gastos/pagos se suman solos (como SumNumbers): "500 comida, 40 tortilla" = 540.
class DiaPage extends StatefulWidget {
  final String fecha;
  const DiaPage({super.key, required this.fecha});
  @override
  State<DiaPage> createState() => _DiaPageState();
}

const _numeros = ['sencillo', 'caja', 'cambio', 'sen_a_bil', 'bil_a_sen', 'total_pdv', 'recargas'];
const _textos = ['ingresos_txt', 'gastos_txt', 'pagos_txt', 'gasto_banca_txt', 'otros_ingresos_txt', 'notas'];

class _DiaPageState extends State<DiaPage> {
  final ctl = <String, TextEditingController>{};
  Rec? ayer;
  Rec original = {};
  double? tpvVentas;
  (double, int)? recTae;
  var listo = false;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  String _txt(Object? v) => v == null || n(v) == 0 ? '' : (n(v) % 1 == 0 ? n(v).toInt().toString() : '${n(v)}');

  Future<void> _cargar() async {
    final d = await Db.dia(widget.fecha) ?? {'fecha': widget.fecha};
    ayer = await Db.diaAnterior(widget.fecha);
    final t = await Db.raw.query('tpv_dia', where: 'fecha=?', whereArgs: [widget.fecha]);
    tpvVentas = t.isEmpty ? null : n(t.first['ventas']);
    final f = DateTime.parse(widget.fecha);
    recTae = (await Db.recargasPorDia(widget.fecha, iso(f.add(const Duration(days: 1)))))[widget.fecha];
    original = d;
    for (final x in denominaciones) {
      ctl['b$x'] = TextEditingController(text: _txt(d['b$x']));
    }
    for (final k in _numeros) {
      ctl[k] = TextEditingController(text: _txt(d[k]));
    }
    for (final k in _textos) {
      final base = k.replaceAll('_txt', '');
      final t = d[k] as String?;
      ctl[k] = TextEditingController(text: t ?? (k == 'notas' ? '' : _txt(d[base])));
    }
    // Día nuevo: se proponen el total del punto de venta y las recargas del día
    if (d['total_pdv'] == null && tpvVentas != null) ctl['total_pdv']!.text = _txt(tpvVentas);
    if (d['recargas'] == null && recTae != null && mounted) {
      final s = context.read<Settings>();
      ctl['recargas']!.text = _txt(recTae!.$1 + s.cargoRecarga * recTae!.$2);
    }
    for (final c in ctl.values) {
      c.addListener(() => setState(() {}));
    }
    if (mounted) setState(() => listo = true);
  }

  Rec _datos() {
    final d = <String, Object?>{'fecha': widget.fecha};
    double? v(String k) => ctl[k]!.text.trim().isEmpty ? null : double.tryParse(ctl[k]!.text.replaceAll(',', ''));
    for (final x in denominaciones) {
      d['b$x'] = v('b$x');
    }
    if (!denominaciones.any((x) => d['b$x'] != null)) d['billetes'] = original['billetes'];
    for (final k in _numeros) {
      d[k] = v(k);
    }
    for (final k in _textos) {
      final t = ctl[k]!.text.trim();
      d[k] = t.isEmpty ? null : t;
      if (k != 'notas') d[k.replaceAll('_txt', '')] = sumNumbers(t);
    }
    d['saldo'] = original['saldo'];
    return calcular(d, ayer);
  }

  Future<void> _guardar() async {
    await Db.guardarDia(_datos());
    avisarCambios();
    if (mounted) Navigator.pop(context);
  }

  Widget _num(String k, String label, {String? ayuda}) => TextField(
        controller: ctl[k],
        keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[-0-9.]'))],
        decoration: InputDecoration(labelText: label, helperText: ayuda),
      );

  Widget _texto(String k, String label, String hint) {
    final suma = sumNumbers(ctl[k]!.text);
    return TextField(
      controller: ctl[k],
      maxLines: null,
      decoration: InputDecoration(labelText: label, hintText: hint, suffixText: suma != 0 ? money(suma) : null),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Settings>();
    final f = DateTime.parse(widget.fecha);
    if (!listo) return Scaffold(appBar: AppBar(), body: const Center(child: CircularProgressIndicator()));
    final r = _datos();
    final esp = const SizedBox(height: 12);
    return Scaffold(
      appBar: AppBar(
        title: Text(toBeginningOfSentenceCase(DateFormat("EEEE d MMM yyyy", 'es').format(f))),
        actions: [IconButton(icon: const Icon(Icons.save), onPressed: _guardar)],
      ),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 100), children: [
        Card(
          color: Theme.of(context).colorScheme.primaryContainer,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(children: [
              Text('Venta del día', style: Theme.of(context).textTheme.labelLarge),
              Text(money(n(r['venta'])), style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold)),
              Text('Banca ${money(n(r['banca']))} · Sencillo total ${money(n(r['sencillo_total']))}'),
              Text('Total global ${money(totalGlobal(r))}'),
              if (r['total_pdv'] != null)
                Text('Diferencia vs PDV: ${money(diferencia(r, sumarRecargas: s.diferenciaConRecargas))}',
                    style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: diferencia(r, sumarRecargas: s.diferenciaConRecargas).abs() < 1 ? Colors.green : Colors.orange)),
              if (ayer != null)
                Text('Ayer (${ayer!['fecha']}): caja ${money(n(ayer!['caja']))}, cambio ${money(n(ayer!['cambio']))}',
                    style: Theme.of(context).textTheme.bodySmall),
            ]),
          ),
        ),
        const SectionTitle('Billetes de hoy'),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final x in denominaciones)
            SizedBox(width: 100, child: _num('b$x', '\$$x', ayuda: n(ctl['b$x']!.text) != 0 ? money(n(ctl['b$x']!.text) * x) : null)),
        ]),
        Padding(padding: const EdgeInsets.only(top: 6), child: Text('Total billetes: ${money(n(r['billetes']))}')),
        const SectionTitle('Caja'),
        _num('sencillo', 'Sencillo (monedas contadas)'),
        esp,
        _num('caja', 'Caja (sencillo que se queda de fondo)'),
        esp,
        _num('cambio', 'Cambio (billetes que se quedan)'),
        const SectionTitle('Lo que entró y salió'),
        _texto('ingresos_txt', 'Ingresos (no son venta)', '350 abono noe, 200 pago cfe'),
        esp,
        _texto('gastos_txt', 'Gastos', '500 comida, 40 tortilla'),
        esp,
        _texto('pagos_txt', 'Pagos a proveedores', '250 tio, 2010 coca'),
        const SectionTitle('Banca'),
        _texto('gasto_banca_txt', 'Gasto de banca', '300'),
        esp,
        _num('sen_a_bil', 'Sencillo a billete'),
        esp,
        _num('bil_a_sen', 'Billete a sencillo'),
        esp,
        _texto('otros_ingresos_txt', 'Otros ingresos', '850 pago von tarjeta'),
        const SectionTitle('Punto de venta y recargas'),
        _num('total_pdv', 'Total PDV (TPVDark)',
            ayuda: tpvVentas != null ? 'TPVDark vendió ${money(tpvVentas!)} este día' : 'Sin datos de TPVDark para este día'),
        if (tpvVentas != null && n(ctl['total_pdv']!.text) != tpvVentas)
          Align(
              alignment: Alignment.centerLeft,
              child: TextButton(onPressed: () => ctl['total_pdv']!.text = _txt(tpvVentas), child: const Text('Usar el de TPVDark'))),
        esp,
        _num('recargas', 'Recargas cobradas',
            ayuda: recTae != null
                ? '${recTae!.$2} recargas por ${money(recTae!.$1)} + ${money(s.cargoRecarga)} c/u = ${money(recTae!.$1 + s.cargoRecarga * recTae!.$2)}'
                : 'No hay recargas leídas de este día'),
        if (recTae != null && n(ctl['recargas']!.text) != recTae!.$1 + s.cargoRecarga * recTae!.$2)
          Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                  onPressed: () => ctl['recargas']!.text = _txt(recTae!.$1 + s.cargoRecarga * recTae!.$2),
                  child: const Text('Usar las de TAE Pocket'))),
        const SectionTitle('Notas'),
        _texto('notas', 'Observaciones del día', ''),
      ]),
      floatingActionButton: FloatingActionButton.extended(
          onPressed: _guardar, icon: const Icon(Icons.save), label: const Text('Guardar')),
    );
  }
}
