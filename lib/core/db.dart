import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'calc.dart';
export 'calc.dart' show Rec;

/// Columnas de un día de Control Ciber.
const camposDia = [
  'b20', 'b50', 'b100', 'b200', 'b500', 'b1000', 'billetes', 'sencillo', 'caja', 'ingresos', 'ingresos_txt',
  'gastos', 'gastos_txt', 'pagos', 'pagos_txt', 'gasto_banca', 'gasto_banca_txt', 'cambio', 'sen_a_bil',
  'bil_a_sen', 'otros_ingresos', 'otros_ingresos_txt', 'total_pdv', 'recargas', 'saldo', 'notas',
  'venta', 'banca', 'sencillo_total',
];
const _textos = {'ingresos_txt', 'gastos_txt', 'pagos_txt', 'gasto_banca_txt', 'otros_ingresos_txt', 'notas'};

/// Tablas que se respaldan en Supabase (allá se llaman `cuentas_<tabla>`).
const tablasRespaldo = {'dias': 'fecha', 'recargas': 'clave', 'nombres': 'telefono', 'abonos': 'id'};

/// Base de datos en el teléfono (funciona sin internet).
/// Cada fila lleva `updated_at` (ms) y `synced` = 0 cuando falta subirla al respaldo.
class Db {
  Db._();
  static late Database _db;
  static Database get raw => _db;

  static Future<void> open({String? ruta}) async {
    _db = await openDatabase(
      ruta ?? p.join(await getDatabasesPath(), 'cuentasdark.db'),
      version: 1,
      onCreate: (db, v) async {
        for (final s in _schema) {
          await db.execute(s);
        }
      },
    );
  }

  static const _sync = 'updated_at INTEGER, synced INTEGER DEFAULT 0, deleted INTEGER DEFAULT 0';

  static final _schema = [
    'CREATE TABLE dias(fecha TEXT PRIMARY KEY, '
        '${camposDia.map((c) => '$c ${_textos.contains(c) ? 'TEXT' : 'REAL'}').join(', ')}, '
        'calc INTEGER DEFAULT 1, $_sync)',
    'CREATE TABLE recargas(clave TEXT PRIMARY KEY, fecha TEXT, compania TEXT, telefono TEXT, monto REAL, '
        'folio TEXT, producto TEXT, proveedor TEXT, origen TEXT, $_sync)',
    'CREATE INDEX ix_rec_fecha ON recargas(fecha)',
    'CREATE INDEX ix_rec_tel ON recargas(telefono)',
    'CREATE TABLE nombres(telefono TEXT PRIMARY KEY, nombre TEXT, notas TEXT, $_sync)',
    'CREATE TABLE abonos(id TEXT PRIMARY KEY, fecha TEXT, monto REAL, proveedor TEXT, notas TEXT, $_sync)',
    'CREATE TABLE art_dia(fecha TEXT, articulo TEXT, descripcion TEXT, cantidad REAL, total REAL, '
        'PRIMARY KEY(fecha, articulo))',
    'CREATE INDEX ix_art_art ON art_dia(articulo)',
    'CREATE TABLE tpv_dia(fecha TEXT PRIMARY KEY, ventas REAL, tickets INTEGER, actualizado INTEGER)',
    'CREATE TABLE kv(k TEXT PRIMARY KEY, v TEXT)',
  ];

  static int get now => DateTime.now().millisecondsSinceEpoch;

  static final _rnd = Random.secure();
  static String newId() {
    final b = List<int>.generate(16, (_) => _rnd.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
  }

  static Future<String?> kv(String k) async {
    final r = await _db.query('kv', where: 'k=?', whereArgs: [k]);
    return r.isEmpty ? null : r.first['v'] as String?;
  }

  static Future<void> setKv(String k, String v) =>
      _db.insert('kv', {'k': k, 'v': v}, conflictAlgorithm: ConflictAlgorithm.replace);

  // ---------------- Histórico de los Excel ----------------
  /// Carga una sola vez assets/historico.json.gz (Control Ciber + TAEPOCKET/RECARGAS unidos).
  static Future<String?> importarHistorico() async {
    if (await kv('historico') != null) return null;
    final gz = await rootBundle.load('assets/historico.json.gz');
    final data = jsonDecode(utf8.decode(gzip.decode(gz.buffer.asUint8List()))) as Map<String, dynamic>;
    return importarJson(data, marca: true);
  }

  static Future<String> importarJson(Map<String, dynamic> data, {bool marca = false}) async {
    final t = now;
    final dias = (data['dias'] as List).cast<Map<String, dynamic>>();
    final rec = (data['recargas'] as List).cast<Map<String, dynamic>>();
    final ab = (data['abonos'] as List).cast<Map<String, dynamic>>();
    final nom = (data['nombres'] as List).cast<Map<String, dynamic>>();
    await _db.transaction((tx) async {
      var b = tx.batch();
      for (final d in dias) {
        final row = <String, Object?>{'fecha': d['fecha'], 'calc': 0, 'updated_at': t, 'synced': 0};
        for (final c in camposDia) {
          if (d[c] != null) row[c] = d[c];
        }
        b.insert('dias', row, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      for (final r in rec) {
        b.insert('recargas', {...r, 'clave': claveRecarga(r), 'origen': 'excel', 'updated_at': t, 'synced': 0},
            conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      for (final a in ab) {
        b.insert('abonos', {...a, 'id': '${a['proveedor']}|${a['fecha']}|${a['monto']}', 'updated_at': t, 'synced': 0},
            conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      for (final x in nom) {
        b.insert('nombres', {...x, 'updated_at': t, 'synced': 0}, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      await b.commit(noResult: true);
      if (marca) await tx.insert('kv', {'k': 'historico', 'v': '$t'}, conflictAlgorithm: ConflictAlgorithm.replace);
    });
    return 'Histórico cargado: ${dias.length} días, ${rec.length} recargas, ${nom.length} nombres.';
  }

  // ---------------- Días ----------------
  static Future<Rec?> dia(String fecha) async {
    final r = await _db.query('dias', where: 'fecha=? AND deleted=0', whereArgs: [fecha]);
    return r.isEmpty ? null : r.first;
  }

  static Future<Rec?> diaAnterior(String fecha) async {
    final r = await _db.query('dias', where: 'fecha<? AND deleted=0', whereArgs: [fecha], orderBy: 'fecha DESC', limit: 1);
    return r.isEmpty ? null : r.first;
  }

  static Future<List<Rec>> dias(String desde, String hasta) =>
      _db.query('dias', where: 'fecha>=? AND fecha<? AND deleted=0', whereArgs: [desde, hasta], orderBy: 'fecha');

  /// Guarda un día calculándolo con el día anterior y recalcula los siguientes días
  /// capturados en la app (los del Excel se quedan con su valor).
  static Future<void> guardarDia(Rec d) async {
    final fecha = d['fecha'] as String;
    var ayer = await diaAnterior(fecha);
    var actual = calcular(d, ayer)..['calc'] = 1;
    await _escribirDia(actual);
    final siguientes = await _db.query('dias', where: 'fecha>? AND deleted=0', whereArgs: [fecha], orderBy: 'fecha');
    for (final s in siguientes) {
      if (s['calc'] != 1) break;
      ayer = actual;
      actual = calcular(s, ayer);
      await _escribirDia(actual);
    }
  }

  static Future<void> _escribirDia(Rec d) async {
    final row = <String, Object?>{'fecha': d['fecha'], 'calc': d['calc'] ?? 1, 'updated_at': now, 'synced': 0, 'deleted': 0};
    for (final c in camposDia) {
      row[c] = d[c];
    }
    await _db.insert('dias', row, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  // ---------------- Recargas ----------------
  /// Guarda recargas nuevas (las repetidas se ignoran). Devuelve cuántas eran nuevas.
  static Future<int> guardarRecargas(List<Rec> lista, String origen) async {
    var nuevas = 0;
    await _db.transaction((tx) async {
      for (final r in lista) {
        final id = await tx.insert(
            'recargas', {...r, 'clave': claveRecarga(r), 'origen': origen, 'updated_at': now, 'synced': 0},
            conflictAlgorithm: ConflictAlgorithm.ignore);
        if (id > 0) nuevas++;
      }
    });
    return nuevas;
  }

  static Future<List<Rec>> recargas(String desde, String hasta, {String? tel}) => _db.rawQuery(
      'SELECT r.*, n.nombre FROM recargas r LEFT JOIN nombres n ON n.telefono=r.telefono AND n.deleted=0 '
      'WHERE r.deleted=0 AND r.fecha>=? AND r.fecha<? ${tel != null ? 'AND r.telefono=?' : ''} ORDER BY r.fecha DESC',
      [desde, hasta, ?tel]);

  /// Monto y número de recargas por día (para la cuenta del día y las gráficas).
  static Future<Map<String, (double, int)>> recargasPorDia(String desde, String hasta) async {
    final r = await _db.rawQuery(
        'SELECT substr(fecha,1,10) f, SUM(monto) m, COUNT(*) c FROM recargas WHERE deleted=0 AND fecha>=? AND fecha<? GROUP BY f',
        [desde, hasta]);
    return {for (final x in r) x['f'] as String: (n(x['m']), (x['c'] as int?) ?? 0)};
  }

  static Future<void> guardarNombre(String tel, String nombre) => _db.insert(
      'nombres', {'telefono': tel, 'nombre': nombre, 'updated_at': now, 'synced': 0, 'deleted': nombre.isEmpty ? 1 : 0},
      conflictAlgorithm: ConflictAlgorithm.replace);

  static Future<void> borrarRecarga(String clave) =>
      _db.update('recargas', {'deleted': 1, 'synced': 0, 'updated_at': now}, where: 'clave=?', whereArgs: [clave]);
}
