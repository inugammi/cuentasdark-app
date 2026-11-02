# Vigilante V3c (2/nov/2026) — video del día, YouTube, clientes a CuentasDark, área de la foto
Solo cambia codigo\cotejo_tpv.py (vigilante_app.py sigue igual que V3b). Respaldo: codigo\_respaldo_antes_V3c\.

En la ventana "Cotejar ventas de TPVDark con el video":
- **Foto de las recargas**: lista para elegir el canal (1-8) + "Dibujar área..." (rectángulo sobre la imagen en vivo del DVR) + "Quitar".
  Busca la cara solo dentro del área; si no hay cara guarda el área como foto. Se guarda `_foto.jpg` (recorte) y `_cuadro.jpg` (imagen completa).
- **Clientes a CuentasDark** (ya NO se crean en TPVDark): tabla `nombres` de %APPDATA%\CuentasDark\cuentasdark.db.
  Si el teléfono no tiene nombre: "RECARGA <COMPAÑÍA> dd/mm/aa hh:mm" (synced=0, la app lo respalda en la nube).
  Si ya tiene nombre no se toca. Foto en %APPDATA%\CuentasDark\fotos\<teléfono>.jpg (nunca reemplaza una existente).
  La app CuentasDark muestra esa foto en Clientes desde el PR inugammi/cuentasdark-app#1 (solo en la PC).
- **Video del día**: "Unir los clips de cada día en un solo video" -> cotejo\AAAA-MM-DD\cotejo_dia_AAAA-MM-DD.mp4 (H.264, ~170 MB/día).
  "Subirlo a YouTube": playlist dd-mm-aaaa, título "Cotejo caja dd-mm-aaaa - N movimientos", descripción con minuto de cada cobro.
  3 intentos (espera 1 y 3 min). No lo resube si no cambió (youtube.json). La casilla de apagar espera a que termine la subida.
- La ventana ahora cabe en pantallas de 768 px (panel con barra de desplazamiento).
- Compilar con C:\Users\Usuario\source\repos\TPVDarkCotejo\_venv_v3.
