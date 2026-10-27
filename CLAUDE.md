# Cuentas Dark — memoria del proyecto

App Android (Flutter) de cuentas diarias de Ciber Dark. Reemplaza los Excel "Control Ciber.xlsm" y
"TAEPOCKET AAAA.xlsx"/"RECARGAS AAAA.xlsx" y lee TPVDark por Supabase. Misma estructura que `inugammi/darkelectronic-app`.

Responder en español, directo y conciso. El usuario no compila: el APK lo hace GitHub Actions al hacer push a `main`
(Releases > CuentasDark.apk). La llave de firma va en el secreto KEYSTORE_BASE64 (nunca subir el .jks). Antes de subir: `flutter analyze` y `flutter test` deben pasar.

## Mapa
- `lib/main.dart` — arranque: carga el histórico la primera vez, trae TPVDark (si `autoSync`), barra inferior con los
  primeros 4 módulos, "Más" para el resto, `TaeAuto` invisible (lee TAE Pocket 1 vez al día).
- `lib/core/calc.dart` — SIN Flutter, probado en `test/calc_test.dart`:
  - `sumNumbers` = función SumNumbers del Excel (suma los números de un texto).
  - `calcular(dia, ayer)` = fórmulas de Control Ciber:
    Venta = Billetes + Sencillo − Caja(ayer) + Gastos + Pagos − Cambio(ayer) − Ingresos;
    Banca = Banca(ayer) − GastoBanca + Billetes + SencilloABillete − BilleteASencillo + OtrosIngresos − Cambio;
    SencilloTotal = SencTot(ayer) − SencilloABillete − Caja + Sencillo + BilleteASencillo; TotalGlobal = Banca + SencTot.
    Diferencia = Venta − TotalPDV + Recargas (hoja 2026; ajuste `diferenciaConRecargas`).
    `banca_en_caja`=1 ("Dejé la banca en caja"): los billetes contados traen la banca de ayer; Venta/Banca usan
    Billetes − Banca(ayer) (`billetesHoy`). `billetes` guarda lo contado.
    Recogidas de TPVDark ("Recoger dinero") = SOLO informativas (monto y hora), NO suman (columnas `recogido(_txt)`
    quedaron sin uso).
  - `campoMovimiento`/`lineaMovimiento`: movimientos de caja de TPVDark → renglón del día (RECOGIDA→ninguno),
    INGRESO→ingresos (no FONDO DE CAJA), INGRESO_FUERA_CAJA→otros_ingresos, RETIRO→gastos (PAGO A PROVEEDOR→pagos),
    PAGO_EMPLEADO→gastos, RETIRO_FUERA_CAJA→gasto_banca.
  - Periodos día/semana(lunes-domingo)/mes/año; `leerFecha` y `filaRecarga` (lee filas del historial de TAE Pocket,
    formato 2025, 2026 y la página vieja "Recargas Más"); `claveRecarga` evita duplicados.
- `lib/core/db.dart` — sqflite. Tablas: `dias` (fecha PK, columnas = `camposDia`, `calc`=0 si viene del Excel, 1 si se
  calcula), `recargas` (clave PK), `nombres` (telefono PK), `abonos`, `art_dia` (fecha+articulo), `tpv_dia`, `kv`.
  `guardarDia` recalcula el día y los siguientes con calc=1. `updated_at`/`synced`/`deleted` para el respaldo.
- `lib/core/tpv.dart` — Supabase de TPVDark (login correo/contraseña como TPVDarkMovil, RLS `authenticated`).
  Lee `v_ventas_dia`, `v_articulos_dia` (si no existen, cae a `ventas`/`ventas_lineas`), `recargas` (estado=1),
  y respalda en `cuentas_dias|recargas|nombres|abonos`.
  `movimientosCaja` lee la vista `v_cuentas_dark_movimientos` (TPVDark V163, schema_supabase_v1_35.sql; tabla
  `caja_movimientos`) a la tabla local `tpv_mov` (con hora `fecha` y `usuario`; pide `usuario_nombre`, si la vista
  no lo tiene cae a `usuario`). El día nuevo se llena solo; botón "Poner N que faltan".
  Al guardar un día se respalda de inmediato: TPVDark V163 toma `cambio + caja` del último día como fondo inicial.
- `lib/core/revision.dart` — Vigilante: `limpiar()` quita recargas repetidas (origen='duplicado', deleted=1,
  restaurables) y `revisar()` lista avisos (días sin capturar, diferencias ≥ $50 vs PDV, recargas que no coinciden,
  lecturas de hoy pendientes, números frecuentes sin nombre). Corre al abrir, tras leer TAE Pocket y tras TPVDark.
  Regla de "misma recarga" en `Db.esMisma`: mismo número, monto ±1, ≤20 min y (mismo folio, ±2 min o una sin folio).
- `Tpv.historicoCompleto` baja ventas/artículos mes por mes desde la primera venta en Supabase (kv `artDesde`);
  se hace sola la primera vez y desde Artículos > ⋮.
- `lib/core/tae.dart` — WebView de taepocketplus.com; JS que junta celdas de todas las `<tr>`; `TaeAuto`.
- `lib/core/charts.dart` — `Barras` y `Lineas` (fl_chart). `ui.dart` — `SelectorPeriodo`, `Dato(s)`, diálogos.
- `lib/modules/*` — un módulo por carpeta, registrado en `lib/modules/registry.dart`.
- `supabase/cuentas_v1.sql` = `lib/modules/tpvdark/sql.dart` (mantener iguales). `cuentas_v2.sql` agrega `banca_en_caja`, `cuentas_v3.sql` agrega `recogido(_txt)` (sql.dart = v1+v2+v3). Cambios nuevos: `cuentas_v4.sql`.
- `assets/historico.json.gz` — Excel unidos (generado con `tool/excel_a_json.py <carpeta con los xlsx> salida.json`
  y luego gzip; quitar abonos con fecha futura). 7,067 días (2005-12-20 a 2026-10-24), 19,550 recargas, 227 nombres.

## Datos de los Excel (para no releerlos)
- Control Ciber: una hoja por año; columnas por nombre de encabezado (cambian entre años). 2005-2009 solo Dia/Semana/Mes;
  2011 casi vacío; 2012 empieza en abril ("EDAD OSCURA"). Billetes: total + conteo $20..$1000. Textos de gastos/pagos al lado.
- TAEPOCKET: hojas ENE..DIC + NOMBRES (teléfono, nombre). Datos pegados desde la columna O; el formato cambia por mes.
  Saldo: abono en col M (fila del día en col H), bono 7.4 %. Cobrado del día = monto + 1 por recarga (L = I + K).
- RECARGAS 2017/2018 y RECARGAS MAS 2022: página vieja (6 % de bono), filas con "a PDF", fecha "dd/mm/yyyy hh:mm:ss a. m.".
- Validación: totales mensuales de recargas = TOTAL MES del Excel en 62 de 71 meses (las diferencias son de < 1 %).

## Relación con TPVDark
- TPVDark (C#, `C:\Users\Usuario\source\repos\TPVDark`) sube a Supabase `ventas`, `ventas_lineas`, `recargas`, etc.
  Su CLAUDE.md está en la raíz de ese repo. TPVDarkMovil (Kotlin) es otra app; esta NO la reemplaza.
- `TAE_URL` de TPVDark = https://taepocketplus.com/inicio.php.

## No leer (ruido)
`build/`, `.dart_tool/`, `android/.gradle`, `assets/historico.json.gz` (binario; usar consultas o el script).
