# Cuentas Dark · cuentas diarias del Ciber

App Android y Windows (Flutter) que reemplaza los Excel **Control Ciber** y **TAEPOCKET / RECARGAS** de Ciber Dark,
y toma de **TPVDark** lo del día a día. Funciona sin internet (base de datos en el teléfono) y se respalda en el Supabase de TPVDark.

## Qué hace
- **Cuentas**: cada día como un renglón de Control Ciber (billetes por denominación, sencillo, caja, cambio, ingresos,
  gastos y pagos escritos como texto que se suman solos, gasto de banca, sencillo↔billete, otros ingresos, total PDV y recargas).
  Calcula Venta del día, Banca, Sencillo total, Total global y la Diferencia contra TPVDark. Vista por **día, semana, mes y año**.
  Puedes corregir cualquier día (también los del Excel) y se recalculan los siguientes.
- **Recargas**: todas las recargas desde 2017, por día/semana/mes/año, por compañía, ganancia (bono % + cargo por recarga) y abonos de saldo.
  Se leen **de la página de TAE Pocket** (taepocketplus.com) dentro de la app, una vez al día, y de la caja de TPVDark.
  También puedes pegar el historial copiado o capturar una recarga a mano.
- **Clientes**: quién recarga (la hoja NOMBRES), cuántas veces y cuánto, por periodo o de todos los años. Pon o cambia nombres.
- **Artículos**: histórico de lo que se vendió en TPVDark por día, semana, mes y año, con gráficas por artículo.
- **Gráficas**: venta por mes comparando años (como la gráfica de Control Ciber), venta por día, por año, recargas y gastos.
- **Histórico incluido**: la primera vez carga los Excel unidos (dic 2005 – oct 2026) desde `assets/historico.json.gz`.

## Instalar en el teléfono
Cada cambio en `main` compila el APK con GitHub Actions. Descárgalo en **Releases** (`CuentasDark.apk`) y ábrelo en el teléfono
(permite "instalar apps desconocidas"). Todos los APK se firman con la misma llave (secreto `KEYSTORE_BASE64` del repo; no se sube al código),
así que las actualizaciones se instalan encima sin perder datos. Mantén el repo privado.

## Instalar en la PC (Windows 10/11, 64 bits)
En **Releases** descarga `CuentasDark-Setup.exe` y ábrelo (no pide administrador; si Windows muestra "Windows protegió su PC",
toca *Más información > Ejecutar de todas formas*). Crea el acceso en el escritorio y en el menú Inicio. Para actualizar,
instala el nuevo encima: tus datos están en `%APPDATA%\CuentasDark` y no se borran. También hay un `CuentasDark-PC-portable.zip`.
En la PC pon los mismos datos de Supabase (Más > TPVDark) y toca **Traer ahora**: baja todo lo que el celular ya respaldó.
TAE Pocket en la PC se abre en el navegador: copia la tabla del historial y en Recargas > 🌐 toca **Pegar lo copiado**.

## Conectar con TPVDark
1. Supabase (una vez): SQL Editor > New query > pega `supabase/cuentas_v1.sql` > RUN (también se copia desde la app: Más > TPVDark).
   Solo crea vistas y tablas nuevas (`v_ventas_dia`, `v_articulos_dia`, `cuentas_*`); no toca TPVDark.
2. En la app: Más > TPVDark > URL, anon key, correo y contraseña (los mismos de TPVDarkMovil) > Probar > Traer ahora.

## TAE Pocket
Recargas > 🌐: entra con tu usuario (la sesión se guarda), abre el historial/reporte y toca **Leer recargas**.
En el menú ⋮ elige **Usar esta página para leer cada día**: desde entonces la app la lee sola al abrirse (una vez al día).

## Estructura
```
lib/core      calc (fórmulas del Excel y lectura de recargas), db, tpv (Supabase), tae (WebView), charts, ui, settings
lib/modules   cuentas, recargas, clientes, articulos, graficas, tpvdark, settings (+ registry.dart)
assets/       historico.json.gz (los Excel unidos)
supabase/     cuentas_v1.sql
tool/         excel_a_json.py (vuelve a generar el histórico desde los Excel)
```
