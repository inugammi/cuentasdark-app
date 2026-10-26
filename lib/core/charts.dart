import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import 'settings.dart';

const coloresSeries = [
  Color(0xFF2E86DE), Color(0xFFE67E22), Color(0xFF27AE60), Color(0xFFC0392B), Color(0xFF8E44AD),
  Color(0xFF16A085), Color(0xFFF1C40F), Color(0xFF7F8C8D),
];

String _corto(double v) => v.abs() >= 1000 ? '${(v / 1000).toStringAsFixed(v.abs() >= 10000 ? 0 : 1)}k' : v.toStringAsFixed(0);

/// Barras simples: una barra por etiqueta. Toca una barra para ver su valor.
class Barras extends StatelessWidget {
  final List<String> etiquetas;
  final List<double> valores;
  final Color? color;
  final double alto;
  final void Function(int i)? alTocar;
  final String Function(double v) formato;
  const Barras(this.etiquetas, this.valores,
      {super.key, this.color, this.alto = 220, this.alTocar, this.formato = money});

  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.primary;
    final paso = (etiquetas.length / 8).ceil().clamp(1, 1000);
    return SizedBox(
      height: alto,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 16, 12, 4),
        child: BarChart(BarChartData(
          barTouchData: BarTouchData(
            touchCallback: (e, r) {
              if (alTocar != null && e is FlTapUpEvent && r?.spot != null) alTocar!(r!.spot!.touchedBarGroupIndex);
            },
            touchTooltipData: BarTouchTooltipData(
              getTooltipItem: (g, gi, rod, ri) =>
                  BarTooltipItem('${etiquetas[g.x]}\n${formato(rod.toY)}', const TextStyle(color: Colors.white)),
            ),
          ),
          gridData: const FlGridData(drawVerticalLine: false),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(),
            rightTitles: const AxisTitles(),
            leftTitles: AxisTitles(
                sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 40,
                    getTitlesWidget: (v, m) => Text(_corto(v), style: const TextStyle(fontSize: 10)))),
            bottomTitles: AxisTitles(
                sideTitles: SideTitles(
                    showTitles: true,
                    getTitlesWidget: (v, m) {
                      final i = v.toInt();
                      if (i < 0 || i >= etiquetas.length || i % paso != 0) return const SizedBox.shrink();
                      return Text(etiquetas[i], style: const TextStyle(fontSize: 10));
                    })),
          ),
          barGroups: [
            for (var i = 0; i < valores.length; i++)
              BarChartGroupData(x: i, barRods: [
                BarChartRodData(
                    toY: valores[i],
                    color: c,
                    width: (260 / (valores.length + 1)).clamp(2, 22).toDouble(),
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(3)))
              ]),
          ],
        )),
      ),
    );
  }
}

/// Una línea por serie (por ejemplo una por año, con los 12 meses), como la gráfica de Control Ciber.
class Lineas extends StatelessWidget {
  final List<String> etiquetas;
  final Map<String, List<double?>> series;
  final double alto;
  const Lineas(this.etiquetas, this.series, {super.key, this.alto = 260});

  @override
  Widget build(BuildContext context) {
    final nombres = series.keys.toList();
    return Column(children: [
      SizedBox(
        height: alto,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 16, 16, 4),
          child: LineChart(LineChartData(
            gridData: const FlGridData(drawVerticalLine: false),
            borderData: FlBorderData(show: false),
            lineTouchData: LineTouchData(
              touchTooltipData: LineTouchTooltipData(
                getTooltipItems: (spots) => [
                  for (final s in spots)
                    LineTooltipItem('${nombres[s.barIndex]} ${etiquetas[s.x.toInt()]}: ${money(s.y)}',
                        TextStyle(color: coloresSeries[s.barIndex % coloresSeries.length], fontSize: 12))
                ],
              ),
            ),
            titlesData: FlTitlesData(
              topTitles: const AxisTitles(),
              rightTitles: const AxisTitles(),
              leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 40,
                      getTitlesWidget: (v, m) => Text(_corto(v), style: const TextStyle(fontSize: 10)))),
              bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                      showTitles: true,
                      interval: 1,
                      getTitlesWidget: (v, m) {
                        final i = v.toInt();
                        if (i < 0 || i >= etiquetas.length) return const SizedBox.shrink();
                        return Text(etiquetas[i], style: const TextStyle(fontSize: 10));
                      })),
            ),
            lineBarsData: [
              for (var k = 0; k < nombres.length; k++)
                LineChartBarData(
                  spots: [
                    for (var i = 0; i < series[nombres[k]]!.length; i++)
                      if (series[nombres[k]]![i] != null) FlSpot(i.toDouble(), series[nombres[k]]![i]!)
                  ],
                  color: coloresSeries[k % coloresSeries.length],
                  barWidth: 2.5,
                  dotData: const FlDotData(show: true),
                ),
            ],
          )),
        ),
      ),
      Wrap(spacing: 12, children: [
        for (var k = 0; k < nombres.length; k++)
          Row(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 12, height: 12, color: coloresSeries[k % coloresSeries.length]),
            const SizedBox(width: 4),
            Text(nombres[k]),
          ])
      ]),
    ]);
  }
}
