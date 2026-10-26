import 'calc.dart';
import 'db.dart';
import 'settings.dart';

/// Algo que el vigilante encontró y conviene revisar.
class Aviso {
  final String titulo, detalle;
  final int nivel; // 0 info, 1 revisar, 2 importante
  final String? fecha; // día que se abre al tocarlo
  final String? telefono; // número que se abre al tocarlo
  const Aviso(this.titulo, this.detalle, {this.nivel = 1, this.fecha, this.telefono});
}

/// El vigilante: quita recargas repetidas y revisa que las cuentas cuadren.
/// Corre al abrir la app, después de leer TAE Pocket o TPVDark, y desde el módulo Revisión.
class Vigilante {
  static Future<int> limpiar() async {
    final q = await Db.limpiarDuplicados();
    if (q > 0) {
      final antes = int.tryParse(await Db.kv('dupQuitadas') ?? '') ?? 0;
      await Db.setKv('dupQuitadas', '${antes + q}');
    }
    return q;
  }

  static Future<List<Aviso>> revisar(Settings s, {int dias = 45}) async {
    final out = <Aviso>[];
    final hoy = soloFecha(DateTime.now());
    final desde = iso(hoy.subtract(Duration(days: dias)));
    final hasta = iso(hoy.add(const Duration(days: 1)));

    // 1. Lecturas de hoy
    final tae = await Db.kv('taeUltima');
    if (s.taeHistorial.isEmpty) {
      out.add(const Aviso('TAE Pocket no está configurado',
          'En Recargas > 🌐 abre el historial y en ⋮ elige "Usar esta página para leer cada día".', nivel: 2));
    } else if (tae != iso(hoy)) {
      out.add(Aviso('TAE Pocket no se ha leído hoy', 'Última lectura: ${tae ?? 'nunca'}. Abre Recargas > 🌐 y toca Leer.'));
    }
    final tpv = await Db.kv('tpvUltima');
    if (s.sbUrl.isEmpty) {
      out.add(const Aviso('TPVDark no está conectado', 'Más > TPVDark: pon los datos de Supabase.', nivel: 2));
    } else if (tpv != iso(hoy)) {
      out.add(Aviso('TPVDark no se ha traído hoy', 'Última vez: ${tpv ?? 'nunca'}. Más > TPVDark > Traer ahora.'));
    }

    // 2. Repetidas quitadas
    final dup = await Db.raw.rawQuery("SELECT COUNT(*) c FROM recargas WHERE origen='duplicado'");
    final nd = (dup.first['c'] as int?) ?? 0;
    if (nd > 0) {
      out.add(Aviso('$nd recargas repetidas quitadas',
          'Eran la misma recarga leída dos veces (TAE Pocket, caja o pegado). Toca "Ver repetidas" para revisarlas o restaurar alguna.',
          nivel: 0));
    }

    // 3. Días
    final cuentas = {for (final d in await Db.dias(desde, hasta)) d['fecha'] as String: d};
    final ventasTpv = {
      for (final x in await Db.raw.query('tpv_dia', where: 'fecha>=? AND fecha<?', whereArgs: [desde, hasta]))
        x['fecha'] as String: n(x['ventas'])
    };
    final rec = await Db.recargasPorDia(desde, hasta);
    for (var d = hoy.subtract(const Duration(days: 1)); iso(d).compareTo(desde) >= 0; d = d.subtract(const Duration(days: 1))) {
      final f = iso(d);
      final c = cuentas[f];
      if (c == null) {
        if ((ventasTpv[f] ?? 0) > 0 || rec[f] != null) {
          out.add(Aviso('$f sin capturar',
              'TPVDark vendió ${money(ventasTpv[f] ?? 0)}${rec[f] != null ? ' y hubo ${rec[f]!.$2} recargas' : ''}.',
              fecha: f));
        }
        continue;
      }
      if (c['total_pdv'] != null) {
        final dif = diferencia(c, sumarRecargas: s.diferenciaConRecargas);
        if (dif.abs() >= 50) {
          out.add(Aviso('$f no cuadra por ${money(dif)}', 'Venta ${money(n(c['venta']))} vs PDV ${money(n(c['total_pdv']))}.',
              nivel: 2, fecha: f));
        }
      } else if ((ventasTpv[f] ?? 0) > 0) {
        out.add(Aviso('$f sin total PDV', 'TPVDark vendió ${money(ventasTpv[f]!)}: ábrelo y toca "Usar el de TPVDark".', fecha: f));
      }
      if (rec[f] != null && c['recargas'] != null) {
        final leidas = rec[f]!.$1 + s.cargoRecarga * rec[f]!.$2;
        if ((leidas - n(c['recargas'])).abs() >= 1) {
          out.add(Aviso('$f: recargas no coinciden',
              'En la cuenta ${money(n(c['recargas']))}, leídas ${money(leidas)} (${rec[f]!.$2} recargas).', fecha: f));
        }
      }
      for (final k in ['gastos', 'pagos', 'ingresos']) {
        final t = c['${k}_txt'] as String?;
        if (t != null && t.trim().isNotEmpty && sumNumbers(t) == 0) {
          out.add(Aviso('$f: $k sin cantidades', '"$t" no tiene números; no suma nada.', fecha: f));
        }
      }
    }

    // 4. Clientes frecuentes sin nombre
    final sin = await Db.raw.rawQuery(
        'SELECT r.telefono, COUNT(*) c FROM recargas r LEFT JOIN nombres n ON n.telefono=r.telefono AND n.deleted=0 '
        'WHERE r.deleted=0 AND r.fecha>=? AND n.nombre IS NULL GROUP BY r.telefono HAVING c>=5 ORDER BY c DESC LIMIT 15',
        [desde]);
    for (final x in sin) {
      out.add(Aviso('${x['telefono']} recargó ${x['c']} veces y no tiene nombre', 'Tócalo para ponerle nombre.',
          nivel: 0, telefono: x['telefono'] as String));
    }
    out.sort((a, b) => b.nivel.compareTo(a.nivel));
    return out;
  }
}
