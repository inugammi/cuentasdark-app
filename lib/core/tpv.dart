import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart' show ConflictAlgorithm;

import 'calc.dart';
import 'db.dart';
import 'revision.dart';
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

  /// Revisa paso a paso la conexión: entrada, tablas de TPVDark, vistas y tablas del respaldo.
  Future<String> probar() async {
    if (!configurado) return '⚠ Falta poner la URL y la anon key.';
    final out = <String>[];
    try {
      _token = null;
      await _h();
      out.add(s.sbEmail.isEmpty ? '⚠ Sin correo: se entra solo con la anon key (las tablas con RLS no van a responder).' : '✅ Entré a Supabase como ${s.sbEmail}');
    } catch (e) {
      return '❌ $e';
    }
    Future<void> paso(String nombre, String ruta, String Function(List<Map<String, dynamic>> r) ok, {String? falta}) async {
      try {
        out.add('✅ $nombre: ${ok(await _get(ruta))}');
      } on _NoExiste {
        out.add('❌ $nombre: no existe${falta != null ? ' ($falta)' : ''}');
      } catch (e) {
        final t = '$e';
        if (RegExp('banca_en_caja|recogido').hasMatch(t)) {
          out.add('❌ $nombre: faltan columnas nuevas (SQL de Cuentas Dark)');
          return;
        }
        out.add('❌ $nombre: ${t.length > 160 ? '${t.substring(0, 160)}…' : t}');
      }
    }

    String ultimo(List<Map<String, dynamic>> r, String c) => r.isEmpty ? 'vacía' : 'último ${r.first[c]}';
    String sub(List<Map<String, dynamic>> r) {
      if (r.isEmpty) return 'vacía (todavía no se sube nada)';
      final ms = n(r.first['updated_at']).toInt();
      return 'último cambio subido ${ms > 1 ? DateTime.fromMillisecondsSinceEpoch(ms).toString().substring(0, 16) : '-'}';
    }

    await paso('Ventas de TPVDark', 'ventas?select=fecha&order=fecha.desc&limit=1', (r) => ultimo(r, 'fecha'));
    await paso('Ventas por día', 'v_ventas_dia?select=dia&order=dia.desc&limit=1', (r) => ultimo(r, 'dia'), falta: 'SQL de Cuentas Dark');
    await paso('Artículos por día', 'v_articulos_dia?select=dia&order=dia.desc&limit=1', (r) => ultimo(r, 'dia'), falta: 'SQL de Cuentas Dark');
    await paso('Recargas de la caja', 'recargas?select=fecha&order=fecha.desc&limit=1', (r) => ultimo(r, 'fecha'));
    await paso('Movimientos de caja', 'v_cuentas_dark_movimientos?select=fecha&order=fecha.desc&limit=1', (r) => ultimo(r, 'fecha'),
        falta: 'schema_supabase_v1_35.sql de TPVDark');
    await paso('Respaldo de días', 'cuentas_dias?select=fecha,updated_at,banca_en_caja,recogido&order=updated_at.desc&limit=1', sub,
        falta: 'SQL de Cuentas Dark');
    for (final t in ['recargas', 'nombres', 'abonos']) {
      await paso('Respaldo de $t', 'cuentas_$t?select=updated_at&order=updated_at.desc&limit=1', sub, falta: 'SQL de Cuentas Dark');
    }
    var pendientes = 0;
    for (final t in tablasRespaldo.keys) {
      pendientes += (await Db.raw.rawQuery('SELECT COUNT(*) c FROM $t WHERE synced=0')).first['c'] as int;
    }
    out.add(pendientes == 0 ? '✅ Todo lo de este equipo ya está respaldado.' : '⏳ $pendientes cambios de este equipo esperan subirse (toca Respaldar cuentas).');
    if (out.any((x) => x.contains('SQL de Cuentas Dark'))) out.add('👉 Corre el SQL de abajo (Copiar SQL de instalación) en Supabase.');
    return out.join('\n');
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

  /// Ingresos, retiros, recogidas y pagos a empleados de la caja (vista v_cuentas_dark_movimientos, TPVDark V163).
  /// Se reemplazan los días leídos para que un movimiento borrado en la caja también se quite aquí.
  Future<int> movimientosCaja(DateTime desde) async {
    const cols = 'uuid,dia,fecha,tipo_cuentas,categoria,concepto,importe,empleado_nombre';
    final q = '&dia=gte.${iso(desde)}&order=fecha';
    List<Map<String, dynamic>> filas;
    try {
      filas = await _todo('v_cuentas_dark_movimientos?select=$cols,usuario_nombre$q');
    } on _NoExiste {
      rethrow;
    } catch (_) {
      filas = await _todo('v_cuentas_dark_movimientos?select=$cols,usuario$q'); // vista sin usuario_nombre
    }
    final b = Db.raw.batch()..delete('tpv_mov', where: 'dia>=?', whereArgs: [iso(desde)]);
    var c = 0;
    for (final x in filas) {
      final tipo = '${x['tipo_cuentas']}';
      if (tipo != 'RECOGIDA' && campoMovimiento(tipo, x['categoria'] as String?) == null) continue;
      b.insert('tpv_mov', {
        'uuid': x['uuid'], 'dia': '${x['dia']}'.substring(0, 10), 'tipo': tipo, 'categoria': x['categoria'],
        'concepto': x['concepto'], 'importe': n(x['importe']), 'empleado': x['empleado_nombre'],
        'fecha': '${x['fecha'] ?? ''}', 'usuario': x['usuario_nombre'] ?? (x['usuario'] == null ? null : 'cajero ${x['usuario']}'),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      c++;
    }
    await b.commit(noResult: true);
    return c;
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
    if (await Db.kv('artDesde') == null) {
      // Primera vez: todo el histórico de ventas y artículos, no solo los últimos días.
      await historicoCompleto((_, _) {});
    }
    final v = await ventas(desde, manana);
    final a = await articulos(desde, manana);
    var r = 0;
    try {
      r = await recargasCaja(desde);
    } catch (_) {}
    var m = -1;
    try {
      m = await movimientosCaja(desde);
    } catch (_) {} // sin la vista (falta schema_supabase_v1_35.sql de TPVDark) no pasa nada
    await Db.setKv('tpvUltima', iso(hoy));
    if (r > 0) await Vigilante.limpiar();
    var msg = 'TPVDark: $v días de ventas, $a artículos/día';
    try {
      msg += '\n${await respaldar()}';
    } on _NoExiste {
      msg += '\nRespaldo: ejecuta supabase/cuentas_v1.sql para activarlo.';
    }
    return '$msg${r > 0 ? ', $r recargas nuevas de la caja' : ''}${m > 0 ? ', $m movimientos de caja' : ''}.';
  }

  /// Fecha de la venta más vieja que hay en Supabase.
  Future<DateTime?> primeraVenta() async {
    final r = await _get('ventas?select=fecha&order=fecha.asc&limit=1');
    return r.isEmpty ? null : DateTime.tryParse((r.first['fecha'] as String).substring(0, 10));
  }

  /// Trae TODO el histórico de ventas y artículos, mes por mes, desde la primera venta en Supabase.
  /// [avance] recibe el mes que va (para la barra de progreso).
  Future<String> historicoCompleto(void Function(String mes, double avance) avance) async {
    final ini = await primeraVenta();
    if (ini == null) return 'No hay ventas en Supabase.';
    final hoy = soloFecha(DateTime.now()).add(const Duration(days: 1));
    var m = DateTime(ini.year, ini.month);
    final total = (hoy.year - m.year) * 12 + hoy.month - m.month + 1;
    var i = 0, filas = 0;
    while (m.isBefore(hoy)) {
      final f = DateTime(m.year, m.month + 1);
      avance('${m.year}-${m.month.toString().padLeft(2, '0')}', i / total);
      await ventas(m, f.isAfter(hoy) ? hoy : f);
      filas += await articulos(m, f.isAfter(hoy) ? hoy : f);
      m = f;
      i++;
    }
    await Db.setKv('artDesde', iso(ini));
    return 'Histórico completo desde ${iso(ini)}: $filas artículos/día.';
  }

  // ---------------- Respaldo de las cuentas ----------------
  /// Baja lo que cambió en otro equipo (celular o PC) y sube lo que cambió en este.
  Future<String> respaldar() async {
    var subidos = 0, bajados = 0;
    final h = await _h();
    for (final e in tablasRespaldo.entries) {
      final t = e.key;
      // Primero baja y luego sube: así un cambio más nuevo de otro equipo no se pisa con uno viejo de aquí.
      final desde = int.tryParse(await Db.kv('bajado_$t') ?? '') ?? 0;
      final inicio = Db.now;
      for (final x in await _todo('cuentas_$t?select=*&updated_at=gt.$desde&order=updated_at')) {
        final local = await Db.raw.query(t, where: '${e.value}=?', whereArgs: [x[e.value]]);
        if (local.isNotEmpty && n(local.first['updated_at']) >= n(x['updated_at'])) continue;
        await Db.raw.insert(t, {...x, 'synced': 1}, conflictAlgorithm: ConflictAlgorithm.replace);
        bajados++;
      }
      await Db.setKv('bajado_$t', '$inicio');
      while (true) {
        final lote = await Db.raw.query(t, where: 'synced=0', limit: 500);
        if (lote.isEmpty) break;
        final r = await http.post(Uri.parse('$_base/rest/v1/cuentas_$t?on_conflict=${e.value}'),
            headers: {...h, 'Content-Type': 'application/json', 'Prefer': 'resolution=merge-duplicates,return=minimal'},
            body: jsonEncode([for (final x in lote) Map.of(x)..remove('synced')]));
        if (r.statusCode == 404) throw _NoExiste('cuentas_$t');
        if (r.statusCode >= 300 && RegExp('banca_en_caja|recogido').hasMatch(r.body)) {
          throw 'Falta un paso en Supabase: ejecuta el SQL de Cuentas Dark (Más > TPVDark > Copiar SQL).';
        }
        if (r.statusCode >= 300) throw 'Respaldo $t: ${r.statusCode} ${r.body}';
        final b = Db.raw.batch();
        for (final x in lote) {
          b.update(t, {'synced': 1}, where: '${e.value}=? AND updated_at=?', whereArgs: [x[e.value], x['updated_at']]);
        }
        await b.commit(noResult: true);
        subidos += lote.length;
      }
    }
    return 'Respaldo: $subidos subidos, $bajados bajados${await _fotos()}';
  }

  /// Fotos de clientes (tabla cuentas_fotos, JPG en base64). Baja las nuevas de otro equipo y sube
  /// las de esta carpeta que cambiaron. updated_at = fecha del archivo, así no rebotan entre equipos.
  Future<String> _fotos() async {
    if (Db.dirFotos.isEmpty) return '';
    final dir = Directory(Db.dirFotos);
    var sub = 0, baj = 0;
    try {
      final h = await _h();
      final desde = int.tryParse(await Db.kv('bajado_fotos') ?? '') ?? 0;
      final inicio = Db.now;
      for (final x in await _todo('cuentas_fotos?select=telefono,updated_at&updated_at=gt.$desde&order=updated_at')) {
        final tel = x['telefono'] as String;
        final t = n(x['updated_at']).toInt();
        final f = File(p.join(dir.path, '$tel.jpg'));
        if (f.existsSync() && f.lastModifiedSync().millisecondsSinceEpoch >= t) continue;
        final r = await _get('cuentas_fotos?select=jpg&telefono=eq.${Uri.encodeQueryComponent(tel)}');
        if (r.isEmpty || r.first['jpg'] == null) continue;
        await dir.create(recursive: true);
        await f.writeAsBytes(base64Decode(r.first['jpg'] as String), flush: true);
        await f.setLastModified(DateTime.fromMillisecondsSinceEpoch(t));
        baj++;
      }
      await Db.setKv('bajado_fotos', '$inicio');
      final hasta = int.tryParse(await Db.kv('subido_fotos') ?? '') ?? 0;
      var nuevo = hasta;
      if (Db.esEscritorio && dir.existsSync()) { // las fotos nacen en la PC (Vigilante)
        for (final f in dir.listSync().whereType<File>()) {
          if (!f.path.toLowerCase().endsWith('.jpg')) continue;
          final t = f.lastModifiedSync().millisecondsSinceEpoch;
          if (t <= hasta) continue;
          final r = await http.post(Uri.parse('$_base/rest/v1/cuentas_fotos?on_conflict=telefono'),
              headers: {...h, 'Content-Type': 'application/json', 'Prefer': 'resolution=merge-duplicates,return=minimal'},
              body: jsonEncode([
                {'telefono': p.basenameWithoutExtension(f.path), 'jpg': base64Encode(await f.readAsBytes()), 'updated_at': t}
              ]));
          if (r.statusCode == 404) throw _NoExiste('cuentas_fotos');
          if (r.statusCode >= 300) throw 'fotos ${r.statusCode}';
          if (t > nuevo) nuevo = t;
          sub++;
        }
      }
      await Db.setKv('subido_fotos', '$nuevo');
    } on _NoExiste {
      return '\nFotos: ejecuta supabase/cuentas_v4.sql (Más > TPVDark > Copiar SQL) para pasarlas al celular.';
    } catch (e) {
      return '\nFotos: no se pudieron sincronizar ($e).';
    }
    return sub + baj == 0 ? '' : ', fotos: $sub subidas, $baj bajadas';
  }
}

class _NoExiste implements Exception {
  final String que;
  _NoExiste(this.que);
  @override
  String toString() => 'No existe $que en Supabase (ejecuta supabase/cuentas_v1.sql).';
}
