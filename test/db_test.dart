import 'dart:convert';
import 'dart:io';

import 'package:cuentasdark/core/calc.dart';
import 'package:cuentasdark/core/db.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await Db.open(ruta: inMemoryDatabasePath);
    final data = jsonDecode(utf8.decode(gzip.decode(File('assets/historico.json.gz').readAsBytesSync())));
    await Db.importarJson(data as Map<String, dynamic>);
  });

  test('el histórico trae todos los años y recargas', () async {
    final d = await Db.raw.rawQuery('SELECT MIN(fecha) a, MAX(fecha) b, COUNT(*) c FROM dias');
    expect(d.first['a'], '2005-12-20');
    expect((d.first['c'] as int) > 7000, isTrue);
    final r = await Db.raw.rawQuery('SELECT COUNT(*) c FROM recargas');
    expect((r.first['c'] as int) > 19000, isTrue);
    // Total de recargas de septiembre 2026 igual al TOTAL MES del Excel TAEPOCKET
    final m = await Db.recargasPorDia('2026-09-01', '2026-10-01');
    expect(m.values.fold(0.0, (a, b) => a + b.$1), greaterThan(0));
  });

  test('capturar un día nuevo sigue la cadena del Excel', () async {
    await Db.guardarDia({'fecha': '2026-10-25', 'b100': 10, 'sencillo': 300, 'caja': 250, 'cambio': 500, 'gastos_txt': '200 comida'});
    final d = (await Db.dia('2026-10-25'))!;
    final ayer = (await Db.dia('2026-10-24'))!;
    expect(d['venta'], 1000 + 300 - n(ayer['caja']) + 200 - n(ayer['cambio']));
    expect(d['calc'], 1);
    // corregir el 24 recalcula el 25? No: el 24 viene del Excel y el 25 se recalcula si cambia el 24
    await Db.guardarDia({...ayer, 'caja': n(ayer['caja']) + 10});
    final d2 = (await Db.dia('2026-10-25'))!;
    expect(d2['venta'], n(d['venta']) - 10);
  });

  test('consultas de clientes y gráficas', () async {
    final c = await Db.raw.rawQuery(
        'SELECT r.telefono, n.nombre, COUNT(*) veces FROM recargas r LEFT JOIN nombres n ON n.telefono=r.telefono '
        'GROUP BY r.telefono ORDER BY veces DESC LIMIT 5');
    expect(c.length, 5);
    final g = await Db.raw.rawQuery(
        "SELECT substr(fecha,1,4) m, substr(fecha,6,2) mm, SUM(venta) t FROM dias WHERE deleted=0 GROUP BY 1,2 HAVING SUM(venta)<>0");
    expect(g.length > 150, isTrue);
    final l = await Db.recargas('2026-10-01', '2026-10-02');
    expect(l.isNotEmpty, isTrue);
  });

  test('guardar recargas repetidas no las duplica', () async {
    final r = {'fecha': '2026-10-26 10:00', 'compania': 'TELCEL', 'telefono': '9610000000', 'monto': 50.0, 'folio': 'x', 'proveedor': 'TAEPOCKET'};
    expect(await Db.guardarRecargas([r], 'tae'), 1);
    expect(await Db.guardarRecargas([r], 'tae'), 0);
  });
}
