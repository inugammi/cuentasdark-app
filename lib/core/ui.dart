import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'calc.dart';

void toast(BuildContext c, String msg) =>
    ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(msg)));

Future<bool> confirm(BuildContext c, String msg, {String ok = 'Sí'}) async =>
    await showDialog<bool>(
      context: c,
      builder: (c) => AlertDialog(content: Text(msg), actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(ok)),
      ]),
    ) ??
    false;

Future<String?> askText(BuildContext c, String title,
    {String initial = '', String? hint, int lines = 1, TextInputType? type, String ok = 'Guardar'}) {
  final ctl = TextEditingController(text: initial);
  return showDialog<String>(
    context: c,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: ctl,
        autofocus: true,
        maxLines: lines,
        keyboardType: type,
        decoration: InputDecoration(hintText: hint),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancelar')),
        FilledButton(onPressed: () => Navigator.pop(c, ctl.text.trim()), child: Text(ok)),
      ],
    ),
  );
}

class SectionTitle extends StatelessWidget {
  final String text;
  final Widget? trailing;
  const SectionTitle(this.text, {super.key, this.trailing});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 8, 4),
        child: Row(children: [
          Expanded(
              child: Text(text,
                  style: Theme.of(context)
                      .textTheme
                      .titleSmall
                      ?.copyWith(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.bold))),
          ?trailing,
        ]),
      );
}

class Empty extends StatelessWidget {
  final IconData icon;
  final String text;
  const Empty(this.icon, this.text, {super.key});
  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 56, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 12),
            Text(text, textAlign: TextAlign.center),
          ]),
        ),
      );
}

/// Tarjeta chica con un número grande (total del periodo, número de recargas...).
class Dato extends StatelessWidget {
  final String titulo;
  final String valor;
  final Color? color;
  final String? sub;
  const Dato(this.titulo, this.valor, {super.key, this.color, this.sub});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(titulo, style: t.labelMedium),
          Text(valor, style: t.titleLarge?.copyWith(fontWeight: FontWeight.bold, color: color)),
          if (sub != null) Text(sub!, style: t.bodySmall),
        ]),
      ),
    );
  }
}

/// Fila de tarjetas Dato que se acomoda al ancho del teléfono.
class Datos extends StatelessWidget {
  final List<Widget> hijos;
  const Datos(this.hijos, {super.key});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Wrap(children: [
          for (final h in hijos)
            SizedBox(width: (MediaQuery.of(context).size.width - 16) / (hijos.length >= 3 ? 3 : hijos.length), child: h)
        ]),
      );
}

/// Selector Día / Semana / Mes / Año con ◀ ▶ para moverse. Lo usan todos los módulos.
class SelectorPeriodo extends StatelessWidget {
  final Periodo periodo;
  final DateTime inicio;
  final void Function(Periodo p, DateTime inicio) cambio;
  final List<Periodo> opciones;
  const SelectorPeriodo(
      {super.key, required this.periodo, required this.inicio, required this.cambio, this.opciones = Periodo.values});

  static String titulo(Periodo p, DateTime i) {
    final f = fin(p, i).subtract(const Duration(days: 1));
    return switch (p) {
      Periodo.dia => DateFormat("EEEE d 'de' MMMM yyyy", 'es').format(i),
      Periodo.semana => '${DateFormat('d MMM', 'es').format(i)} – ${DateFormat('d MMM yyyy', 'es').format(f)}',
      Periodo.mes => DateFormat('MMMM yyyy', 'es').format(i),
      Periodo.anio => '${i.year}',
    };
  }

  @override
  Widget build(BuildContext context) {
    final hoy = soloFecha(DateTime.now());
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
        child: SegmentedButton<Periodo>(
          segments: [for (final p in opciones) ButtonSegment(value: p, label: Text(periodoNombre[p]!))],
          selected: {periodo},
          showSelectedIcon: false,
          onSelectionChanged: (s) => cambio(s.first, inicio_(s.first, inicio)),
        ),
      ),
      Row(children: [
        IconButton(icon: const Icon(Icons.chevron_left), onPressed: () => cambio(periodo, mover(periodo, inicio, -1))),
        Expanded(
          child: InkWell(
            onTap: () async {
              final d = await showDatePicker(
                  context: context, initialDate: inicio, firstDate: DateTime(2005), lastDate: DateTime(hoy.year + 1, 12, 31));
              if (d != null) cambio(periodo, inicio_(periodo, d));
            },
            child: Text(titulo(periodo, inicio),
                textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
          ),
        ),
        IconButton(
            icon: const Icon(Icons.chevron_right),
            onPressed: mover(periodo, inicio, 1).isAfter(hoy) ? null : () => cambio(periodo, mover(periodo, inicio, 1))),
        IconButton(
            tooltip: 'Hoy', icon: const Icon(Icons.today), onPressed: () => cambio(periodo, inicio_(periodo, hoy))),
      ]),
    ]);
  }

  static DateTime inicio_(Periodo p, DateTime d) => inicioDe(p, d);
}
