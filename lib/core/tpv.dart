import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:sqflite/sqflite.dart' show ConflictAlgorithm;

import 'calc.dart';
import 'db.dart';
import 'settings.dart';

/// Conexión con TPVDark a través de su Supabase (la misma cuenta que la caja y TPVDarkMovil).
/// Lee ventas del día, artículos vendidos y recargas registradas en la caja,
/// y guarda/descarga el respaldo de las cuentas (tablas cuentas_*).
class Tpv {
  final Settings s;
  Tpv(this.s);

  static String? _token;
  static int _vence = 0;

  bool get configurado => s.sbUrl.isNotEmpty && s.sbKey.isNotEmpty;
  String get _base => s.sbUrl.trim().replaceAll(RegExp(r'/+$'), '');

  Future<Map<String, String>> _h() async {
    if (s.sbEmail.isNotEmpty && (_token == null || Db.now > _vence)) await _entrar();
    return {'apikey': s.sbKey, 'Authorization': 'Bearer ${_token ?? s.sbKey}'};
  }

  Future<void> _entrar() async {
    final r = await http.post(Uri.parse('$_base/auth/v1/token?grant_type=password'),
        headers: {'apikey': s.sbKey, 'Content-Type': 'application/json'},
        body: jsonEncode({'email': s.sbEmail, 'password': s.sbPass}));
    if (r.statusCode != 200) throw 'No pude entrar a Supabase (${r.statusCode}). Revisa correo y contraseña.';
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    _token = j['access_token'] as String;
    _vence = Db.now + ((j['expires_in'] as num?)?.toInt() ?? 3600) * 1000 - 60000;
  }

  Future<List<Map<String, dynamic>>> _get(String ruta) async {
    final r = await http.get(Uri.parse('$_base/rest/v1/$ruta'), headers: await _h());
    if (r.statusCode == 404) throw _NoExiste(ruta);
    if (r.statusCode >= 300) throw 'Error ${r.statusCode} en ${ruta.split('?').first}: ${r.body}';
    return (jsonDecode(r.body) as List).cast<Map<String, dynamic>>();
  }

  /// Supabase entrega máx. 1000 filas por consulta: pide por páginas.
  Future<List<Map<String, dynamic>>> _todo(String ruta) async {
    final out = <Map<String, dynamic>>[];
    for (var desde = 0;; desde += 1000) {
      final a = await _get('$ruta&limit=1000&offset=$desde');
      out.addAll(a);
      if (a.length < 1000) return out;
    }
  }

  Future<String> probar() async {
    await _get('ventas?select=uuid&limit=1');
    return 'Conexión con TPVDark correcta ✅';
  }

  /// Ventas por día (sin anuladas) -> tabla tpv_dia y campo "total pdv" de cada día.
  Future<int> ventas(DateTime desde, DateTime hasta) async {
    Map<String, (double, int)> dias = {};
    try {
      for (final x in await _todo('v_ventas_dia?select=dia,ventas,tickets&dia=gte.${iso(desde)}&dia=lt.${iso(hasta)}&order=dia')) {
        dias[x['dia'] as String] = (n(x['ventas']), n(x['tickets']).toInt());
      }
    } on _NoExiste {
      // Sin la vista de cuentas_v1.sql: se suman las ventas una por una.
      for (final v in await _todo('ventas?select=fecha,total&estado=neq.9&fecha=gte.${iso(desde)}T00:00:00'
          '&fecha=lt.${iso(hasta)}T00:00:00&order=fecha')) {
        final f = (v['fecha'] as String).substring(0, 10);
        final a = dias[f] ?? (0.0, 0);
        dias[f] = (a.$1 + n(v['total']), a.$2 + 1);
      }
    }
    final b = Db.raw.batch();
    for (final e in dias.entries) {
      b.insert('tpv_dia', {'fecha': e.key, 'ventas': e.value.$1, 'tickets': e.value.$2, 'actualizado': Db.now},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await b.commit(noResult: true);
    return dias.length;
  }

  /// Artículos vendidos por día -> tabla art_dia.
  Future<int> articulos(DateTime desde, DateTime hasta) async {
    final filas = <String, Rec>{};
    void suma(String dia, String art, String desc, double cant, double tot) {
      final k = '$dia|$art';
      final a = filas[k] ?? {'fecha': dia, 'articulo': art, 'descripcion': desc, 'cantidad': 0.0, 'total': 0.0};
      a['cantidad'] = n(a['cantidad']) + cant;
      a['total'] = n(a['total']) + tot;
      if (desc.isNotEmpty) a['descripcion'] = desc;
      filas[k] = a;
    }

    try {
      for (final x in await _todo('v_articulos_dia?select=*&dia=gte.${iso(desde)}&dia=lt.${iso(hasta)}&order=dia')) {
        suma(x['dia'] as String, '${x['articulo'] ?? ''}', '${x['descripcion'] ?? ''}', n(x['cantidad']), n(x['total']));
      }
    } on _NoExiste {
      final ventas = await _todo('ventas?select=uuid,fecha&estado=neq.9&fecha=gte.${iso(desde)}T00:00:00'
          '&fecha=lt.${iso(hasta)}T00:00:00&order=fecha');
      final dia = {for (final v in ventas) v['uuid'] as String: (v['fecha'] as String).substring(0, 10)};
      final ids = dia.keys.toList();
      for (var i = 0; i < ids.length; i += 80) {
        final trozo = ids.sublist(i, i + 80 > ids.length ? ids.length : i + 80);
        for (final l in await _todo('ventas_lineas?select=venta_uuid,articulo,descripcion,cantidad,total'
            '&venta_uuid=in.(${trozo.join(',')})&order=id')) {
          suma(dia[l['venta_uuid']]!, '${l['articulo'] ?? ''}', '${l['descripcion'] ?? ''}', n(l['cantidad']), n(l['total']));
        }
      }
    }
    await Db.raw.transaction((tx) async {
      await tx.delete('art_dia', where: 'fecha>=? AND fecha<?', whereArgs: [iso(desde), iso(hasta)]);
      final b = tx.batch();
      for (final f in filas.values) {
        if ((f['articulo'] as String).isEmpty) f['articulo'] = f['descripcion'];
        b.insert('art_dia', f, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await b.commit(noResult: true);
    });
    return filas.length;
  }

  /// Recargas que se cobraron en la caja de TPVDark (tabla recargas).
  Future<int> recargasCaja(DateTime desde) async {
    final lista = <Rec>[];
    for (final x in await _todo('recargas?select=fecha,compania,producto,telefono,monto,estado'
        '&estado=eq.1&fecha=gte.${iso(desde)}T00:00:00&order=fecha')) {
      final f = leerFecha((x['fecha'] as String).replaceFirst('T', ' '));
      final tel = telefono('${x['telefono'] ?? ''}');
      if (f == null || tel == null) continue;
      lista.add({
        'fecha': fechaHora(f),
        'compania': '${x['compania'] ?? ''}'.replaceAll('_', ' ').toUpperCase(),
        'telefono': tel,
        'monto': n(x['monto']),
        'folio': '',
        'producto': '${x['producto'] ?? ''}',
        'proveedor': 'TAEPOCKET',
      });
    }
    return Db.guardarRecargas(lista, 'tpv');
  }

  /// Trae todo lo del día a día: ventas y artículos de los últimos días y recargas de la caja.
  Future<String> sincronizar({int dias = 3}) async {
    final hoy = soloFecha(DateTime.now());
    final manana = hoy.add(const Duration(days: 1));
    final ultima = DateTime.tryParse(await Db.kv('tpvUltima') ?? '');
    var desde = hoy.subtract(Duration(days: ultima == null ? s.diasArticulos : dias));
    if (ultima != null && ultima.subtract(const Duration(days: 1)).isBefore(desde)) {
      desde = ultima.subtract(const Duration(days: 1));
    }
    final v = await ventas(desde, manana);
    final a = await articulos(desde, manana);
    var r = 0;
    try {
      r = await recargasCaja(desde);
    } catch (_) {}
    await Db.setKv('tpvUltima', iso(hoy));
    var msg = 'TPVDark: $v días de ventas, $a artículos/día';
    try {
      msg += '\n${await respaldar()}';
    } on _NoExiste {
      msg += '\nRespaldo: ejecuta supabase/cuentas_v1.sql para activarlo.';
    }
    return '$msg${r > 0 ? ', $r recargas nuevas de la caja' : ''}.';
  }

  // ---------------- Respaldo de las cuentas ----------------
  /// Sube lo que cambió en el teléfono y baja lo que cambió en otro teléfono.
  Future<String> respaldar() async {
    var subidos = 0, bajados = 0;
    final h = await _h();
    for (final e in tablasRespaldo.entries) {
      final t = e.key;
      while (true) {
        final lote = await Db.raw.query(t, where: 'synced=0', limit: 500);
        if (lote.isEmpty) break;
        final r = await http.post(Uri.parse('$_base/rest/v1/cuentas_$t?on_conflict=${e.value}'),
            headers: {...h, 'Content-Type': 'application/json', 'Prefer': 'resolution=merge-duplicates,return=minimal'},
            body: jsonEncode([for (final x in lote) Map.of(x)..remove('synced')]));
        if (r.statusCode == 404) throw _NoExiste('cuentas_$t');
        if (r.statusCode >= 300) throw 'Respaldo $t: ${r.statusCode} ${r.body}';
        final b = Db.raw.batch();
        for (final x in lote) {
          b.update(t, {'synced': 1}, where: '${e.value}=? AND updated_at=?', whereArgs: [x[e.value], x['updated_at']]);
        }
        await b.commit(noResult: true);
        subidos += lote.length;
      }
      final desde = int.tryParse(await Db.kv('bajado_$t') ?? '') ?? 0;
      final inicio = Db.now;
      for (final x in await _todo('cuentas_$t?select=*&updated_at=gt.$desde&order=updated_at')) {
        final local = await Db.raw.query(t, where: '${e.value}=?', whereArgs: [x[e.value]]);
        if (local.isNotEmpty && n(local.first['updated_at']) >= n(x['updated_at'])) continue;
        await Db.raw.insert(t, {...x, 'synced': 1}, conflictAlgorithm: ConflictAlgorithm.replace);
        bajados++;
      }
      await Db.setKv('bajado_$t', '$inicio');
    }
    return 'Respaldo: $subidos subidos, $bajados bajados';
  }
}

class _NoExiste implements Exception {
  final String que;
  _NoExiste(this.que);
  @override
  String toString() => 'No existe $que en Supabase (ejecuta supabase/cuentas_v1.sql).';
}
