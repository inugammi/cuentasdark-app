import 'package:cuentasdark/core/calc.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('SumNumbers suma los números del texto', () {
    expect(sumNumbers('500 comida, 427.5  tarjetas y tienda 430 control'), 1357.5);
    expect(sumNumbers(''), 0);
    expect(sumNumbers(null), 0);
  });

  test('el día da lo mismo que Control Ciber (20 oct 2026)', () {
    final ayer = {'fecha': '2026-10-19', 'caja': 294.5, 'cambio': 3150.0, 'banca': 0.0, 'sencillo_total': 22150.0};
    final hoy = {
      'fecha': '2026-10-20', 'b20': 5, 'b50': 10, 'b100': 10, 'b200': 1, 'b500': 2, 'sencillo': 1072.0,
      'caja': 272.0, 'cambio': 2500.0, 'gasto_banca_txt': '300',
      'gastos_txt': '500 comida 40 tortilla 500 deposito banco 105 elotes y papas',
      'pagos_txt': '250 tio 195 yakult 1462 bimbo',
    };
    final r = calcular(hoy, ayer);
    expect(r['billetes'], 2800);
    expect(r['gastos'], 1145);
    expect(r['pagos'], 1907);
    expect(r['venta'], 3479.5);
    expect(r['banca'], 0);
    expect(r['sencillo_total'], 22950);
    expect(totalGlobal(r), 22950);
  });

  test('banca dejada en caja: se resta la banca de ayer', () {
    final ayer = {'fecha': '2026-10-19', 'caja': 0.0, 'cambio': 0.0, 'banca': 2000.0, 'sencillo_total': 0.0};
    final normal = calcular({'fecha': '2026-10-20', 'b500': 6}, ayer);
    final junto = calcular({'fecha': '2026-10-20', 'b500': 10, 'banca_en_caja': 1}, ayer);
    expect(junto['billetes'], 5000);
    expect(billetesHoy(junto, ayer), 3000);
    expect(junto['venta'], normal['venta']);
    expect(junto['banca'], 5000);
  });

  test('movimientos de caja de TPVDark van a su renglón', () {
    expect(campoMovimiento('RECOGIDA', 'RECOLECCION DE CAJA'), 'recogido_txt');
    expect(campoMovimiento('INGRESO', 'FONDO DE CAJA'), null);
    expect(campoMovimiento('INGRESO_FUERA_CAJA', 'OTRO INGRESO'), 'otros_ingresos_txt');
    expect(campoMovimiento('RETIRO', 'PAGO A PROVEEDOR'), 'pagos_txt');
    expect(campoMovimiento('PAGO_EMPLEADO', 'PAGO A EMPLEADO'), 'gastos_txt');
    expect(lineaMovimiento({'importe': 350.0, 'concepto': 'abono noe 2026', 'categoria': 'ABONO CLIENTE'}), '350 abono noe');
    expect(sumNumbers(lineaMovimiento({'importe': 1200, 'empleado': 'Luis', 'concepto': 'semana 43'})), 1200);
    final ayer = {'fecha': '2026-10-19', 'caja': 0.0, 'cambio': 0.0, 'banca': 0.0, 'sencillo_total': 0.0};
    final r = calcular({'fecha': '2026-10-20', 'b500': 2, 'recogido_txt': '2000 recogida'}, ayer);
    expect(r['venta'], 3000);
    expect(r['banca'], 3000);
  });

  test('semanas de lunes a domingo y meses', () {
    expect(iso(inicio(Periodo.semana, DateTime(2026, 10, 25))), '2026-10-19');
    expect(iso(fin(Periodo.mes, DateTime(2026, 12))), '2027-01-01');
    expect(iso(mover(Periodo.anio, DateTime(2026), -1)), '2025-01-01');
  });

  test('lee fechas de TAE Pocket y de la página vieja', () {
    expect(leerFecha('01 oct 2026, 07:26'), DateTime(2026, 10, 1, 7, 26));
    expect(leerFecha('21/09/2022 13:12'), DateTime(2022, 9, 21, 13, 12));
    expect(leerFecha('15/01/2018 09:30:37 p. m.'), DateTime(2018, 1, 15, 21, 30));
    expect(leerFecha('16/01/2018 12:05:00 a. m.'), DateTime(2018, 1, 16, 0, 5));
  });

  test('fila de historial TAE Pocket 2026', () {
    final r = filaRecarga(['1', 'Telcel_sin_limite', '50', '50', '9616683089', '571742', '01 oct 2026, 07:26', 'Ver Ticket'])!;
    expect(r['telefono'], '9616683089');
    expect(r['monto'], 50);
    expect(r['compania'], 'TELCEL SIN LIMITE');
    expect(r['folio'], '571742');
    expect(r['fecha'], '2026-10-01 07:26');
  });

  test('fila de historial TAE Pocket 2025', () {
    final r = filaRecarga(['2', '100', '100', '9619174384', '01/01/2025 13:06', 'telcel', '130977', 'WEB'])!;
    expect(r['monto'], 100);
    expect(r['compania'], 'TELCEL');
    expect(r['folio'], '130977');
  });

  test('fila de Recargas Más (página vieja)', () {
    final r = filaRecarga(['a PDF', '34416084', '15/01/2018 09:30:37 p. m.', 'TELCEL', 'PDRYSV6846', 'CIBER DARK',
        '9612344992', '100', '638485', 'EXITO', ' ', '00 respuesta OK', '8', 'web', 'Telcel 100'])!;
    expect(r['monto'], 100);
    expect(r['compania'], 'TELCEL');
    expect(r['folio'], '638485');
    expect(r['telefono'], '9612344992');
  });

  test('pegar texto copiado con tabuladores', () {
    final l = pegarRecargas('#\tCompañía\tMonto\tMonto\tNúmero\tFolio\tFecha\n'
        '1\tBait\t30\t30\t9611955721\t2691386232308380\t01 oct 2026, 07:40\tVer Ticket\n'
        '2\tIusacell_att\t100\t100\t9615018499\t401516\t01 oct 2026, 08:35\tVer Ticket');
    expect(l.length, 2);
    expect(l[1]['monto'], 100);
    expect(claveRecarga(l[0]), 'TAEPOCKET|2026-10-01 07:40|9611955721|30.0');
  });

  test('una recarga fallida no cuenta', () {
    expect(filaRecarga(['1', 'Telcel', '50', '50', '9616683089', '1', '01 oct 2026, 07:26', 'Fallida']), isNull);
  });
}
