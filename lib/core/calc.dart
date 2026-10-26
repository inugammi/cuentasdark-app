/// Cálculos de Control Ciber (sin Flutter, para poder probarlos).
library;

typedef Rec = Map<String, Object?>;

double n(Object? v) => v is num ? v.toDouble() : double.tryParse('${v ?? ''}'.replaceAll(',', '')) ?? 0;

/// Igual que la función SumNumbers del Excel: suma todos los números que aparecen en el texto.
/// "500 comida, 427.5 tarjetas" -> 927.5
double sumNumbers(String? texto) {
  if (texto == null) return 0;
  var t = 0.0;
  for (final m in RegExp(r'-?\d+(?:[.,]\d+)?').allMatches(texto)) {
    t += double.tryParse(m.group(0)!.replaceAll(',', '.')) ?? 0;
  }
  return t;
}

const denominaciones = [20, 50, 100, 200, 500, 1000];

double billetes(Rec d) {
  final conteo = denominaciones.any((x) => d['b$x'] != null && n(d['b$x']) != 0);
  if (!conteo) return n(d['billetes']);
  return denominaciones.fold(0.0, (s, x) => s + n(d['b$x']) * x);
}

/// Calcula Venta del día, Banca y Sencillo total con las fórmulas de Control Ciber:
///   Dia     = Billetes + Sencillo − Caja(ayer) + Gastos + Pagos − Cambio(ayer) − Ingresos
///   Banca   = Banca(ayer) − GastoBanca + Billetes + SencilloABillete − BilleteASencillo + OtrosIngresos − Cambio
///   SencTot = SencTot(ayer) − SencilloABillete − Caja + Sencillo + BilleteASencillo
/// Devuelve una copia de [d] con venta, banca, sencillo_total, billetes y los totales de texto.
Rec calcular(Rec d, Rec? ayer) {
  final r = Map<String, Object?>.from(d);
  for (final k in ['ingresos', 'gastos', 'pagos', 'gasto_banca', 'otros_ingresos']) {
    final t = d['${k}_txt'] as String?;
    if (t != null && t.trim().isNotEmpty) r[k] = sumNumbers(t);
  }
  final a = ayer ?? const {};
  final contado = billetes(r);
  r['billetes'] = contado;
  // "Dejé la banca en caja": lo contado trae también la banca de ayer; se resta para sacar lo de hoy.
  final bil = contado - (n(r['banca_en_caja']) == 1 ? n(a['banca']) : 0);
  r['venta'] = bil + n(r['sencillo']) - n(a['caja']) + n(r['gastos']) + n(r['pagos']) - n(a['cambio']) - n(r['ingresos']);
  r['banca'] = n(a['banca']) - n(r['gasto_banca']) + bil + n(r['sen_a_bil']) - n(r['bil_a_sen']) +
      n(r['otros_ingresos']) - n(r['cambio']);
  r['sencillo_total'] = n(a['sencillo_total']) - n(r['sen_a_bil']) - n(r['caja']) + n(r['sencillo']) + n(r['bil_a_sen']);
  return r;
}

/// Billetes que entraron hoy (sin la banca de ayer si se dejó en caja).
double billetesHoy(Rec d, Rec? ayer) => billetes(d) - (n(d['banca_en_caja']) == 1 ? n(ayer?['banca']) : 0);

double totalGlobal(Rec d) => n(d['banca']) + n(d['sencillo_total']);

/// Diferencia contra el punto de venta. En tu hoja 2026 es Dia − total pdv + Recargas.
double diferencia(Rec d, {bool sumarRecargas = true}) =>
    n(d['venta']) - n(d['total_pdv']) + (sumarRecargas ? n(d['recargas']) : 0);

// ---------------- Periodos ----------------
enum Periodo { dia, semana, mes, anio }

const periodoNombre = {Periodo.dia: 'Día', Periodo.semana: 'Semana', Periodo.mes: 'Mes', Periodo.anio: 'Año'};

DateTime soloFecha(DateTime d) => DateTime(d.year, d.month, d.day);

/// Inicio del periodo que contiene [d]. Las semanas van de lunes a domingo, como en tu Excel.
DateTime inicio(Periodo p, DateTime d) => switch (p) {
      Periodo.dia => soloFecha(d),
      Periodo.semana => soloFecha(d).subtract(Duration(days: d.weekday - 1)),
      Periodo.mes => DateTime(d.year, d.month),
      Periodo.anio => DateTime(d.year),
    };

DateTime inicioDe(Periodo p, DateTime d) => inicio(p, d);

/// Fin (exclusivo) del periodo que empieza en [i].
DateTime fin(Periodo p, DateTime i) => switch (p) {
      Periodo.dia => DateTime(i.year, i.month, i.day + 1),
      Periodo.semana => DateTime(i.year, i.month, i.day + 7),
      Periodo.mes => DateTime(i.year, i.month + 1),
      Periodo.anio => DateTime(i.year + 1),
    };

DateTime mover(Periodo p, DateTime i, int pasos) => switch (p) {
      Periodo.dia => DateTime(i.year, i.month, i.day + pasos),
      Periodo.semana => DateTime(i.year, i.month, i.day + 7 * pasos),
      Periodo.mes => DateTime(i.year, i.month + pasos),
      Periodo.anio => DateTime(i.year + pasos),
    };

String iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

// ---------------- Recargas ----------------
const _meses = {
  'ene': 1, 'feb': 2, 'mar': 3, 'abr': 4, 'may': 5, 'jun': 6, 'jul': 7, 'ago': 8, 'sep': 9, 'oct': 10,
  'nov': 11, 'dic': 12, 'jan': 1, 'apr': 4, 'aug': 8, 'dec': 12,
};

/// Lee fechas como las da TAE Pocket ("01 oct 2026, 07:26", "21/09/2022 13:12")
/// o la página vieja ("15/01/2018 09:30:37 p. m.").
DateTime? leerFecha(String s) {
  final t = s.trim().toLowerCase();
  var m = RegExp(r'^(\d{1,2})/(\d{1,2})/(\d{4})\s+(\d{1,2}):(\d{2})(?::(\d{2}))?\s*([ap])?').firstMatch(t);
  if (m != null) {
    var h = int.parse(m[4]!);
    if (m[7] == 'p' && h < 12) h += 12;
    if (m[7] == 'a' && h == 12) h = 0;
    return DateTime(int.parse(m[3]!), int.parse(m[2]!), int.parse(m[1]!), h, int.parse(m[5]!));
  }
  m = RegExp(r'^(\d{1,2})\s+([a-z]{3})[a-z]*\.?\s+(\d{4}),?\s+(\d{1,2}):(\d{2})').firstMatch(t);
  if (m != null) {
    final mes = _meses[m[2]];
    if (mes == null) return null;
    return DateTime(int.parse(m[3]!), mes, int.parse(m[1]!), int.parse(m[4]!), int.parse(m[5]!));
  }
  m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})[ t](\d{2}):(\d{2})').firstMatch(t);
  if (m != null) {
    return DateTime(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!), int.parse(m[4]!), int.parse(m[5]!));
  }
  return null;
}

String fechaHora(DateTime d) =>
    '${iso(d)} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

const _noCompania = {
  'a pdf', 'exito', 'web', 'app', 'android', 'ios', 'ciber dark', 'ver ticket', 'ticket', 'ver', 'exitosa', 'aprobada',
};

String? telefono(String s) {
  final t = s.trim().replaceAll(RegExp(r'[\s-]'), '');
  return RegExp(r'^\d{10}$').hasMatch(t) ? t : null;
}

/// Convierte una fila de la tabla de historial (celdas de texto) en una recarga.
/// Sirve para lo que lee la app de la página y para lo que pegas copiado.
Rec? filaRecarga(List<String> celdas, {String proveedor = 'TAEPOCKET'}) {
  final c = celdas.map((e) => e.trim()).toList();
  final p = c.indexWhere((e) => telefono(e) != null);
  final d = c.indexWhere((e) => leerFecha(e) != null);
  if (p < 0 || d < 0) return null;
  if (c.any((e) => RegExp(r'fallid|rechaz|error|cancelad', caseSensitive: false).hasMatch(e))) return null;
  double? monto(int i) => i >= 0 && i < c.length && i != p && i != d
      ? double.tryParse(c[i].replaceAll(RegExp(r'[\$,\s]'), ''))
      : null;
  final viejo = c.any((e) => const {'a pdf', 'exito', 'ciber dark'}.contains(e.toLowerCase()));
  var m = viejo ? monto(p + 1) : null;
  m ??= monto(p - 1);
  m ??= monto(p + 1);
  // La tabla nueva de TAE Pocket: # | Compañía | Monto | Monto | Número | Folio | Fecha
  if (m == null) {
    for (var i = 0; i < c.length; i++) {
      final v = monto(i);
      if (v != null && v > 0 && v < 5000 && c[i].length < 9 && i != 0) {
        m = v;
        break;
      }
    }
  }
  if (m == null || m <= 0) return null;
  final cia = viejo && d + 1 < c.length
      ? c[d + 1]
      : c.firstWhere(
          (e) => RegExp(r'^[A-Za-zÁÉÍÓÚáéíóúñÑ_ ]{2,30}$').hasMatch(e) && !_noCompania.contains(e.toLowerCase()),
          orElse: () => '');
  String folio = '';
  if (viejo) {
    folio = p + 2 < c.length ? c[p + 2] : '';
  } else {
    final ci = c.indexOf(cia);
    for (final i in [p + 1, if (ci >= 0) ci + 1]) {
      if (i < c.length && i != d && c[i].isNotEmpty && RegExp(r'^[0-9A-Za-z.+E-]{3,}$').hasMatch(c[i]) &&
          telefono(c[i]) == null && monto(i) != m) {
        folio = c[i];
        break;
      }
    }
  }
  final f = leerFecha(c[d])!;
  return {
    'fecha': fechaHora(f),
    'compania': cia.replaceAll('_', ' ').trim().toUpperCase(),
    'telefono': telefono(c[p]),
    'monto': m,
    'folio': folio,
    'proveedor': proveedor,
  };
}

/// Clave única de una recarga (para no repetirla aunque se lea varias veces).
String claveRecarga(Rec r) => '${r['proveedor']}|${r['fecha']}|${r['telefono']}|${n(r['monto'])}';

/// Texto pegado (copiado de la página o del Excel): una fila por renglón, celdas por tabulador.
List<Rec> pegarRecargas(String texto, {String proveedor = 'TAEPOCKET'}) {
  final out = <Rec>[];
  for (final linea in texto.split(RegExp(r'\r?\n'))) {
    if (linea.trim().isEmpty) continue;
    var celdas = linea.split('\t');
    if (celdas.length < 4) celdas = linea.split(RegExp(r'\s{2,}|;'));
    final r = filaRecarga(celdas, proveedor: proveedor);
    if (r != null) out.add(r);
  }
  return out;
}
