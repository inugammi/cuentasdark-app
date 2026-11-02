"""
Cotejo TPVDark <-> video del DVR (opción del Vigilante).

Por cada venta, recarga, trámite o movimiento de caja de TPVDark en las fechas elegidas:
  1. calcula a qué hora del DVR corresponde (reloj del DVR medido en cada corrida + ajuste
     del reloj de la caja),
  2. baja del DVR solo ese tramo del canal de la caja (loadfile.cgi),
  3. guarda un clip con una leyenda de lo cobrado (tipo, ticket, importe, artículos),
  4. en las recargas toma una foto del cliente (canal y área elegidos) y, si su teléfono no
     tiene nombre en CuentasDark, lo da de alta ahí como "RECARGA <COMPAÑÍA> <fecha hora>"
     con la foto en %APPDATA%\\CuentasDark\\fotos\\<teléfono>.jpg (V3c),
  5. si se pide, une los clips de cada día en un solo video y lo sube a YouTube (V3c).

TPVDark solo se LEE (V3c: ya no se crean clientes en TPVDark).
Los clips quedan en <carpeta de salida>\\cotejo\\AAAA-MM-DD\\ con cotejo.json (registro).
"""
import json
import os
import queue
import re
import sqlite3
import subprocess
import threading
import time
import unicodedata
import uuid
import zipfile
from datetime import datetime, timedelta
from xml.sax.saxutils import escape

import tkinter as tk
from tkinter import ttk, filedialog, messagebox

import cv2
import numpy as np

BD_TPV = r"C:\ProgramData\TPVDark\tpvdark.db"
COTEJO_DEFECTO = {"canal": 1, "canal_foto": 5, "antes": 10, "despues": 20,
                  "ajuste_caja": 0, "terminales": "", "minimo": 0.0,
                  "ventas": True, "recargas": True, "tramites": True, "caja": True,
                  "clientes": True, "auto": False, "bd": BD_TPV,
                  # V3c
                  "area_foto": None, "unir": False, "youtube": False, "bd_cuentas": ""}
TIPOS = ("VENTA", "RECARGA", "TRAMITE", "CAJA")


# ------------------------------------------------------------------ utilidades
def ascii_txt(texto):
    """cv2.putText no dibuja acentos ni ñ: 'Trámite Ñandú' -> 'Tramite Nandu'."""
    t = unicodedata.normalize("NFKD", str(texto or ""))
    return "".join(c for c in t if ord(c) < 128 and not unicodedata.combining(c))


def dinero(v):
    return f"${float(v or 0):,.2f}"


def nombre_archivo(texto):
    return re.sub(r'[\\/:*?"<>|\s]+', "_", ascii_txt(texto)).strip("_")[:80]


def cfg_cotejo(cfg):
    return dict(COTEJO_DEFECTO, **cfg.get("cotejo", {}))


def lista_terminales(texto):
    try:
        return sorted({int(t) for t in re.split(r"[,\s;]+", texto or "") if t.strip()})
    except ValueError:
        return []


# ------------------------------------------------------------- datos TPVDark
def abrir_bd(ruta, escribir=False):
    if escribir:
        cn = sqlite3.connect(ruta, timeout=30, isolation_level=None)
        cn.execute("PRAGMA busy_timeout=30000")
    else:
        cn = sqlite3.connect(f"file:{ruta}?mode=ro", uri=True, timeout=30)
    cn.row_factory = sqlite3.Row
    return cn


def leer_movimientos(c, dia):
    """Lista de movimientos del día (dicts) ordenados por hora de la caja."""
    terms = lista_terminales(c["terminales"])
    d0, d1 = f"{dia:%Y-%m-%d} 00:00:00", f"{dia:%Y-%m-%d} 23:59:59"
    movs = []
    with abrir_bd(c["bd"]) as cn:
        recargas = {r["FACTURA_REF"]: dict(r) for r in cn.execute(
            "SELECT * FROM RECARGAS WHERE ESTADO = 1 AND FECHA BETWEEN ? AND ?",
            (f"{dia - timedelta(days=1):%Y-%m-%d} 12:00:00", d1)) if r["FACTURA_REF"]}
        tramites = {}
        for t in cn.execute("SELECT * FROM TRAMITES WHERE FECHA BETWEEN ? AND ?",
                            (f"{dia - timedelta(days=1):%Y-%m-%d} 12:00:00", d1)):
            tramites[f"{t['SERIE']}-{int(t['CODIGO'] or 0):06d}"] = dict(t)

        for f in cn.execute("""
SELECT TIPFAC, CODFAC, FECFAC, TOTFAC, CLIFAC, CNOFAC, FORMA_COBRO, ESTFAC,
       COALESCE(TERMINAL_ORIGEN, TERFAC, 0) AS TERM
FROM FACTURAS WHERE FECFAC BETWEEN ? AND ? AND COALESCE(ESTFAC,0) <> 9
  AND substr(FECFAC, 12) <> '00:00:00' ORDER BY FECFAC""", (d0, d1)):
            term = int(f["TERM"] or 0)
            if terms and term not in terms:
                continue
            ref = f"{f['TIPFAC']}-{int(f['CODFAC']):06d}"
            lineas = [f"{ascii_txt(l['DESLFA'])[:46]}  x{l['CANLFA']:g}  {dinero(l['TOTLFA'])}"
                      for l in cn.execute("SELECT DESLFA, CANLFA, TOTLFA FROM F_LFA WHERE TIPLFA = ? "
                                          "AND CODLFA = ? ORDER BY POSLFA",
                                          (f["TIPFAC"], f["CODFAC"]))]
            rec, tra = recargas.get(ref), tramites.get(ref)
            tipo = "RECARGA" if rec else "TRAMITE" if tra else "VENTA"
            if not c[{"VENTA": "ventas", "RECARGA": "recargas", "TRAMITE": "tramites"}[tipo]]:
                continue
            if float(f["TOTFAC"] or 0) < float(c["minimo"] or 0):
                continue
            m = {"clave": f"F{ref}", "tipo": tipo, "ref": ref, "hora": f["FECFAC"],
                 "importe": float(f["TOTFAC"] or 0), "terminal": term,
                 "cliente": int(f["CLIFAC"] or 0), "nombre_cliente": f["CNOFAC"] or "",
                 "pago": f["FORMA_COBRO"] or "", "lineas": lineas,
                 "concepto": lineas[0] if lineas else ""}
            if rec:
                m.update(recarga_id=rec["ID"], compania=rec["COMPANIA"] or "",
                         telefono=rec["TELEFONO"] or "", producto=rec["PRODUCTO"] or "",
                         hora_pedido=rec["FECHA"],
                         concepto=f"{rec['COMPANIA']} {rec['TELEFONO']}")
            if tra:
                m["concepto"] = f"{tra['TIPO']} {tra['DETALLE'] or ''}".strip()
            movs.append(m)

        if c["caja"]:
            for r in cn.execute("SELECT * FROM CAJA_MOV WHERE FECHA BETWEEN ? AND ? ORDER BY FECHA",
                                (d0, d1)):
                if terms and int(r["CAJA"] or 0) not in terms:
                    continue
                if float(r["IMPORTE"] or 0) < float(c["minimo"] or 0):
                    continue
                signo = "INGRESO" if int(r["TIPO"]) > 0 else "RETIRO"
                movs.append({"clave": f"C{r['UUID']}", "tipo": "CAJA", "ref": signo,
                             "hora": r["FECHA"], "importe": float(r["IMPORTE"]),
                             "terminal": int(r["CAJA"] or 0), "cliente": 0, "nombre_cliente": "",
                             "pago": r["FORMA_PAGO"] or "",
                             "concepto": ascii_txt(f"{r['CATEGORIA']}: {r['CONCEPTO']}"),
                             "lineas": [ascii_txt(f"{signo} {r['CATEGORIA']}: {r['CONCEPTO']}")[:60]]})
    movs.sort(key=lambda m: m["hora"])
    return movs


# ------------------------------------- V3c: cliente de recarga en CuentasDark
def carpeta_cuentas():
    return os.path.join(os.environ.get("APPDATA", os.path.expanduser("~")), "CuentasDark")


def bd_cuentas(c):
    return c.get("bd_cuentas") or os.path.join(carpeta_cuentas(), "cuentasdark.db")


def tel_limpio(tel):
    t = re.sub(r"\D", "", tel or "")
    return t[-10:] if len(t) > 10 else t


def guardar_en_cuentasdark(c, m, jpg):
    """Tabla 'nombres' de CuentasDark (telefono PK, nombre, notas + updated_at/synced/deleted, la
    misma que usa la app; synced=0 => la app lo respalda en Supabase cuentas_nombres).
    Si el teléfono ya tiene nombre no se toca. La foto va a <CuentasDark>\\fotos\\<tel>.jpg y
    nunca reemplaza una que ya exista. Devuelve (texto, nuevo)."""
    tel = tel_limpio(m.get("telefono"))
    if len(tel) < 8:
        return "sin teléfono: no se guardó", False
    ruta = bd_cuentas(c)
    if not os.path.exists(ruta):
        return f"no encuentro CuentasDark ({ruta})", False
    texto, nuevo = "", False
    cn = sqlite3.connect(ruta, timeout=30, isolation_level=None)
    try:
        cn.execute("PRAGMA busy_timeout=30000")
        cn.execute("BEGIN IMMEDIATE")
        r = cn.execute("SELECT nombre, deleted FROM nombres WHERE telefono = ?", (tel,)).fetchone()
        if r and (r[0] or "").strip() and not r[1]:
            texto = f"CuentasDark: ya se llama {r[0]}"
        else:
            fecha = datetime.strptime(m["hora"], "%Y-%m-%d %H:%M:%S")
            cia = (m.get("compania") or "SIN COMPAÑÍA").upper()
            nombre = f"RECARGA {cia} {fecha:%d/%m/%y %H:%M}"
            notas = (f"Vigilante: recarga #{m['recarga_id']}, ticket {m['ref']}, "
                     f"{m.get('producto', '')}. Foto en fotos\\{tel}.jpg. Ponle el nombre real.")
            cn.execute("""INSERT INTO nombres (telefono, nombre, notas, updated_at, synced, deleted)
                          VALUES (?, ?, ?, ?, 0, 0)
                          ON CONFLICT(telefono) DO UPDATE SET nombre = excluded.nombre,
                             notas = excluded.notas, updated_at = excluded.updated_at,
                             synced = 0, deleted = 0""",
                       (tel, nombre, notas, int(time.time() * 1000)))
            texto, nuevo = f"CuentasDark: alta {nombre}", True
        cn.execute("COMMIT")
    except Exception:
        try:
            cn.execute("ROLLBACK")
        except sqlite3.Error:
            pass
        raise
    finally:
        cn.close()
    if jpg:
        carpeta = os.path.join(os.path.dirname(ruta), "fotos")
        os.makedirs(carpeta, exist_ok=True)
        foto = os.path.join(carpeta, f"{tel}.jpg")
        if os.path.exists(foto):
            texto += " (ya tenía foto)"
        else:
            with open(foto, "wb") as f:
                f.write(jpg)
            texto += " (foto puesta)"
    return texto, nuevo


# ------------------------------------------------------------------- DVR
def reloj_dvr(dvr):
    """Segundos que el DVR va ADELANTADO respecto a esta PC (negativo = atrasado)."""
    medidas = []
    for _ in range(3):
        t0 = time.time()
        txt = dvr._get("/cgi-bin/global.cgi?action=getCurrentTime", timeout=10).text
        t1 = time.time()
        m = re.search(r"(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})", txt)
        if not m:
            raise RuntimeError("El DVR no dio su hora.")
        dvr_t = datetime.strptime(m[1], "%Y-%m-%d %H:%M:%S").timestamp() + 0.5
        medidas.append(dvr_t - (t0 + t1) / 2)
    medidas.sort()
    return medidas[1]


def bajar_tramo(dvr, canal, ini, fin, destino, stop):
    """Baja del DVR solo [ini, fin] del canal (1 = primera cámara). Devuelve bytes bajados."""
    f = lambda t: t.strftime("%Y-%m-%d%%20%H:%M:%S")
    ruta = (f"/cgi-bin/loadfile.cgi?action=startLoad&channel={canal}"
            f"&startTime={f(ini)}&endTime={f(fin)}&subtype=0")
    r = dvr.s.get(dvr.base + ruta, timeout=60, stream=True)
    try:
        if r.status_code == 401:
            raise RuntimeError("Usuario o contraseña del DVR incorrectos.")
        if r.status_code in (400, 404):
            return 0                                 # sin grabación en ese horario
        r.raise_for_status()
        total = 0
        with open(destino, "wb") as s:
            for trozo in r.iter_content(1 << 20):
                if stop.is_set():
                    raise RuntimeError("Detenido.")
                s.write(trozo)
                total += len(trozo)
        return total
    finally:
        r.close()


def filtrar_tramo(V, ruta, destino, canal0, ini, fin):
    """Como V.filtrar_dav pero devuelve también la hora del primer y último cuadro bueno."""
    import mmap
    import struct

    buenos, primero, ultimo, fechas = 0, None, None, {}
    if os.path.getsize(ruta) < 64:
        return 0, None, None
    with open(ruta, "rb") as f, open(destino, "wb") as s:
        b = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
        n = len(b)
        i = b.find(b"DHAV")
        while 0 <= i <= n - 32:
            largo = struct.unpack_from("<I", b, i + 12)[0]
            if largo < 32 or i + largo > n or b[i + largo - 8:i + largo - 4] != b"dhav":
                i = b.find(b"DHAV", i + 4)
                continue
            v = struct.unpack_from("<I", b, i + 16)[0]
            if v not in fechas:
                try:
                    t = V.fecha_dhav(v)
                    fechas[v] = t if ini - timedelta(seconds=3) <= t <= fin + timedelta(seconds=3) else None
                except ValueError:
                    fechas[v] = None
            t = fechas[v]
            if b[i + 6] == canal0 and t is not None:
                s.write(b[i:i + largo])
                buenos += 1
                primero = primero or t
                ultimo = t
            i = b.find(b"DHAV", i + largo)
        b.close()
    return buenos, primero, ultimo


def remux(V, origen, destino):
    ff = V.ruta_ffmpeg()
    if not ff:
        raise RuntimeError("No se encontró ffmpeg.")
    r = subprocess.run([ff, "-y", "-hide_banner", "-loglevel", "error", "-f", "dhav", "-i", origen,
                        "-map", "0:v:0", "-c", "copy", destino], capture_output=True, timeout=600,
                       creationflags=0x08000000 if os.name == "nt" else 0)
    return r.returncode == 0 and os.path.exists(destino) and os.path.getsize(destino) > 0


# ------------------------------------------------------------ leyenda y foto
def leyenda(m, hora_dvr):
    t = datetime.strptime(m["hora"], "%Y-%m-%d %H:%M:%S")
    titulo = {"VENTA": "VENTA", "RECARGA": "RECARGA", "TRAMITE": "TRAMITE", "CAJA": m["ref"]}[m["tipo"]]
    ticket = f" {m['ref']}" if m["tipo"] != "CAJA" else ""
    lineas = [f"{titulo}{ticket}  {dinero(m['importe'])}  {m['pago']}".strip(),
              f"Caja {m['terminal']}  {t:%d-%m-%Y %H:%M:%S}  (DVR {hora_dvr:%H:%M:%S})"]
    if m["tipo"] == "RECARGA":
        lineas.append(f"{m.get('compania', '')}  Tel {m.get('telefono', '')}")
    cuerpo = m["lineas"][:5]
    if len(m["lineas"]) > 5:
        cuerpo.append(f"... y {len(m['lineas']) - 5} articulo(s) mas")
    return [ascii_txt(x) for x in lineas + cuerpo]


def dibujar_leyenda(frame, lineas, resaltar):
    if not lineas:
        return
    h, w = frame.shape[:2]
    esc = max(0.5, w / 1280 * 0.75)
    alto = int(30 * esc / 0.75)
    caja_h = alto * len(lineas) + 12
    caja_w = int(w * 0.62)
    capa = frame.copy()
    color = (0, 90, 0) if resaltar else (20, 20, 20)
    cv2.rectangle(capa, (0, h - caja_h), (caja_w, h), color, -1)
    cv2.addWeighted(capa, 0.6, frame, 0.4, 0, frame)
    for k, txt in enumerate(lineas):
        y = h - caja_h + alto * (k + 1)
        grosor = 2 if k == 0 else 1
        cv2.putText(frame, txt, (10, y), cv2.FONT_HERSHEY_SIMPLEX, esc * (1.1 if k == 0 else 0.9),
                    (255, 255, 255), grosor, cv2.LINE_AA)


_CASCADA = None


def detector_caras():
    global _CASCADA
    if _CASCADA is None:
        _CASCADA = False
        import sys
        bases = [getattr(cv2, "data", None) and cv2.data.haarcascades,
                 os.path.join(getattr(sys, "_MEIPASS", ""), "cv2", "data"),
                 os.path.join(os.path.dirname(cv2.__file__), "data")]
        for b in bases:
            if b and os.path.exists(os.path.join(b, "haarcascade_frontalface_default.xml")):
                cc = cv2.CascadeClassifier(os.path.join(b, "haarcascade_frontalface_default.xml"))
                if not cc.empty():
                    _CASCADA = cc
                    break
    return _CASCADA or None


def area_px(area, w, h):
    """V3c: área elegida (0-1) -> (x0, y0, x1, y1) en píxeles; None = toda la imagen."""
    if not area:
        return 0, 0, w, h
    x0, y0, x1, y1 = area
    x0, x1 = sorted((int(x0 * w), int(x1 * w)))
    y0, y1 = sorted((int(y0 * h), int(y1 * h)))
    if x1 - x0 < 16 or y1 - y0 < 16:
        return 0, 0, w, h
    return max(0, x0), max(0, y0), min(w, x1), min(h, y1)


def mejor_cara(frame, area=None):
    """(área, x, y, w, h) de la cara más grande (dentro del área elegida) o None."""
    det = detector_caras()
    if det is None:
        return None
    h0, w0 = frame.shape[:2]
    ax0, ay0, ax1, ay1 = area_px(area, w0, h0)
    gris = cv2.equalizeHist(cv2.cvtColor(frame[ay0:ay1, ax0:ax1], cv2.COLOR_BGR2GRAY))
    caras = det.detectMultiScale(gris, scaleFactor=1.1, minNeighbors=5, minSize=(40, 40))
    if len(caras) == 0:
        return None
    x, y, w, h = max(caras, key=lambda c: c[2] * c[3])
    return (int(w * h), int(x) + ax0, int(y) + ay0, int(w), int(h))


def recorte_foto(frame, cara, area=None):
    """JPG: cuadro de 256x256 centrado en la cara; sin cara, el área elegida (máx. 640 px) o el
    centro de la imagen."""
    h, w = frame.shape[:2]
    if not cara and area:
        x0, y0, x1, y1 = area_px(area, w, h)
        recorte = frame[y0:y1, x0:x1]
        esc = min(1.0, 640 / max(recorte.shape[:2]))
        if esc < 1:
            recorte = cv2.resize(recorte, None, fx=esc, fy=esc, interpolation=cv2.INTER_AREA)
        ok, buf = cv2.imencode(".jpg", recorte, [cv2.IMWRITE_JPEG_QUALITY, 90])
        return buf.tobytes() if ok else None
    if cara:
        _, x, y, cw, ch = cara
        lado = int(max(cw, ch) * 2.4)
        cx, cy = x + cw // 2, y + ch // 2 + int(ch * 0.2)
    else:
        lado = min(w, h)
        cx, cy = w // 2, h // 2
    lado = min(lado, w, h)
    x0 = min(max(0, cx - lado // 2), w - lado)
    y0 = min(max(0, cy - lado // 2), h - lado)
    recorte = cv2.resize(frame[y0:y0 + lado, x0:x0 + lado], (256, 256), interpolation=cv2.INTER_AREA)
    ok, buf = cv2.imencode(".jpg", recorte, [cv2.IMWRITE_JPEG_QUALITY, 90])
    return buf.tobytes() if ok else None


def hacer_clip(V, mp4, destino, lineas, t_primero, t_objetivo, buscar_cara, area=None):
    """Reescribe el clip con la leyenda (resaltada 4 s alrededor del cobro). Si buscar_cara,
    devuelve (frame completo, cara) del cuadro con la cara más grande; si no, el del cobro."""
    cap = V.abrir_video(mp4)
    fps = cap.get(cv2.CAP_PROP_FPS) or 15
    if fps < 1 or fps > 60:
        fps = 15
    w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    esc = V.Escritor(destino, fps, w, h)
    idx, mejor, cobro = 0, None, None
    try:
        while True:
            ok, fr = cap.read()
            if not ok:
                break
            seg = (t_primero + timedelta(seconds=idx / fps) - t_objetivo).total_seconds()
            if buscar_cara and abs(seg) <= 25 and idx % max(1, int(fps // 3)) == 0:
                cara = mejor_cara(fr, area)
                if cara and (mejor is None or cara[0] > mejor[1][0]):
                    mejor = (fr.copy(), cara)
            if cobro is None and seg >= 0:
                cobro = fr.copy()
            dibujar_leyenda(fr, lineas, abs(seg) <= 2)
            esc.write(fr)
            idx += 1
    finally:
        cap.release()
        esc.cerrar()
    if mejor:
        return mejor
    return (cobro, None) if cobro is not None else (None, None)


# ------------------------------------------------- V3c: video del día + YouTube
def duracion(V, ruta):
    cap = V.abrir_video(ruta)
    try:
        fps = cap.get(cv2.CAP_PROP_FPS) or 15
        n = cap.get(cv2.CAP_PROP_FRAME_COUNT) or 0
        return n / fps if fps > 0 else 0
    finally:
        cap.release()


def unir_dia(V, carpeta, dia, filas, q):
    """Une los clips 'ok' del día en orden de hora: cotejo_dia_AAAA-MM-DD.mp4 (H.264).
    Devuelve (ruta, índice [(segundo, fila)]) o (None, [])."""
    filas = sorted((f for f in filas if f.get("estado") == "ok" and f.get("clip")
                    and os.path.exists(f["clip"])), key=lambda f: f.get("hora", ""))
    if not filas:
        return None, []
    ff = V.ruta_ffmpeg()
    if not ff:
        raise RuntimeError("No se encontró ffmpeg para unir los clips.")
    indice, t = [], 0.0
    lista = os.path.join(carpeta, "_lista_union.txt")
    with open(lista, "w", encoding="utf-8") as f:
        for fila in filas:
            indice.append((t, fila))
            t += duracion(V, fila["clip"])
            f.write("file '" + fila["clip"].replace("\\", "/").replace("'", "'\\''") + "'\n")
    destino = os.path.join(carpeta, f"cotejo_dia_{dia:%Y-%m-%d}.mp4")
    tmp = destino + ".parcial.mp4"
    q.put(("estado", f"{dia:%d-%m-%Y}: uniendo {len(filas)} clips en un video..."))
    sin_ventana = 0x08000000 if os.name == "nt" else 0
    base = [ff, "-y", "-hide_banner", "-loglevel", "error", "-f", "concat", "-safe", "0",
            "-i", lista, "-an", "-r", "15", "-pix_fmt", "yuv420p"]
    try:
        for codec in (["-c:v", "libx264", "-preset", "veryfast", "-crf", "26"],
                      ["-c:v", "mpeg4", "-q:v", "5"]):
            r = subprocess.run(base + codec + [tmp], capture_output=True, timeout=7200,
                               creationflags=sin_ventana)
            if r.returncode == 0 and os.path.exists(tmp) and os.path.getsize(tmp) > 0:
                os.replace(tmp, destino)
                return destino, indice
        raise RuntimeError("ffmpeg no pudo unir los clips: "
                           + r.stderr.decode("utf-8", "replace")[-300:])
    finally:
        for x in (lista, tmp):
            try:
                os.remove(x)
            except OSError:
                pass


def subir_dia(V, cfg, carpeta, dia, ruta, indice, q, stop):
    """Sube el video del día a YouTube (playlist dd-mm-aaaa, como el Vigilante) con 3 intentos.
    No lo vuelve a subir si los clips no cambiaron. Devuelve texto para el resumen."""
    firma = "|".join(f["clave"] for _, f in indice)
    marca = os.path.join(carpeta, "youtube.json")
    try:
        with open(marca, encoding="utf-8") as f:
            previo = json.load(f)
        if previo.get("firma") == firma and previo.get("video"):
            return f"ya estaba en YouTube ({previo['video']})"
    except (OSError, ValueError):
        pass
    if not os.path.exists(V.YT_TOKEN):
        return "YouTube no está conectado (botón 'Conectar YouTube')"
    playlist = (datetime.now() if cfg.get("fecha_pl") == "Fecha de hoy" else dia).strftime("%d-%m-%Y")
    total = sum(f["importe"] for _, f in indice if f.get("tipo") != "CAJA")
    titulo = f"Cotejo caja {dia:%d-%m-%Y} - {len(indice)} movimientos"
    desc = (f"Cotejo de TPVDark con el video del DVR, {dia:%d-%m-%Y}.\n"
            f"{len(indice)} movimientos con video, cobrado {dinero(total)}.\n\n")
    desc += "\n".join(f"{V.fmt_t(seg)} {f['tipo']} {f['ref']} {dinero(f['importe'])} ({f['hora']})"
                      for seg, f in indice)
    priv = V.PRIVACIDAD.get(cfg.get("privacidad", "Privado"), "private")
    error = None
    for intento in range(1, V.INTENTOS_YT + 1):
        if stop.is_set():
            return "subida detenida"
        try:
            q.put(("estado", f"{dia:%d-%m-%Y}: subiendo a YouTube (intento {intento})..."))
            yt = V.youtube_servicio()
            vid, _ = V.yt_subir(yt, ruta, titulo, desc, priv, playlist, lambda fr: q.put((
                "progreso", fr, f"{dia:%d-%m-%Y}: subiendo a YouTube {fr * 100:.0f}%")))
            with open(marca, "w", encoding="utf-8") as f:
                json.dump({"firma": firma, "video": vid, "fecha": f"{datetime.now():%Y-%m-%d %H:%M}"}, f)
            return f"subido a YouTube ({vid}, playlist {playlist})"
        except Exception as e:
            error = e
            if intento < V.INTENTOS_YT:
                espera = 60 if intento == 1 else 180
                q.put(("estado", f"Error al subir a YouTube (intento {intento} de {V.INTENTOS_YT}): "
                                 f"{e}. Se reintenta en {espera // 60} min."))
                stop.wait(espera)
    return f"no se pudo subir a YouTube: {error}"


# --------------------------------------------------------------- registro
def carpeta_dia(cfg, dia):
    ruta = os.path.join(cfg.get("salida") or os.path.join(os.getcwd(), "eventos"), "cotejo",
                        f"{dia:%Y-%m-%d}")
    os.makedirs(ruta, exist_ok=True)
    return ruta


def leer_registro(carpeta):
    try:
        with open(os.path.join(carpeta, "cotejo.json"), encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def guardar_registro(carpeta, reg):
    tmp = os.path.join(carpeta, "cotejo.json.tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(reg, f, indent=1, ensure_ascii=False)
    os.replace(tmp, os.path.join(carpeta, "cotejo.json"))


# ------------------------------------------------------------- el trabajo
def ejecutar(V, cfg, q, stop, dias, rehacer=False):
    """q recibe ('estado', txt), ('progreso', 0..1, txt), ('cotejo', fila) y ('fin', txt)."""
    c = cfg_cotejo(cfg)
    d = dict(V.DVR_DEFECTO, **cfg.get("dvr", {}))
    if not d["ip"] or not d["clave"]:
        q.put(("fin", "Falta configurar el DVR (botón 'Descarga automática del DVR')."))
        return
    if not os.path.exists(c["bd"]):
        q.put(("fin", f"No encuentro la base de TPVDark: {c['bd']}"))
        return
    dvr = V.conectar_dvr(d)
    q.put(("estado", "Midiendo el reloj del DVR..."))
    desfase = reloj_dvr(dvr)
    q.put(("estado", f"El reloj del DVR va {abs(desfase):.0f} s "
                     f"{'adelantado' if desfase >= 0 else 'atrasado'} respecto a esta PC."))
    tmp = os.path.join(V.APP_DIR, "descargas", "cotejo")
    os.makedirs(tmp, exist_ok=True)
    tot = {"ok": 0, "sin": 0, "err": 0, "cli": 0}
    extra = []
    for dia in sorted(set(dias)):
        if stop.is_set():
            break
        carpeta = carpeta_dia(cfg, dia)
        reg = leer_registro(carpeta)
        movs = leer_movimientos(c, dia)
        q.put(("estado", f"{dia:%d-%m-%Y}: {len(movs)} movimiento(s) en TPVDark."))
        for n, m in enumerate(movs, 1):
            if stop.is_set():
                break
            previo = reg.get(m["clave"])
            if previo and not rehacer and previo.get("estado") in ("ok", "sin video"):
                q.put(("cotejo", previo))
                continue
            pref = f"{dia:%d-%m-%Y} [{n}/{len(movs)}] {m['tipo']} {m['ref']} {dinero(m['importe'])}"
            q.put(("progreso", n / max(1, len(movs)), pref))
            fila = {"clave": m["clave"], "fecha": f"{dia:%Y-%m-%d}", "hora": m["hora"][11:],
                    "tipo": m["tipo"], "ref": m["ref"], "caja": m["terminal"],
                    "importe": m["importe"], "concepto": m["concepto"], "estado": "",
                    "clip": "", "foto": "", "cliente": ""}
            try:
                fila.update(cotejar_uno(V, c, dvr, desfase, m, carpeta, tmp, stop))
            except Exception as e:
                if stop.is_set():
                    break
                fila["estado"] = f"error: {e}"
            tot["ok" if fila["estado"] == "ok" else "sin" if fila["estado"] == "sin video"
                else "err"] += 1
            if fila.get("cliente_nuevo"):
                tot["cli"] += 1
            reg[m["clave"]] = fila
            guardar_registro(carpeta, reg)
            q.put(("cotejo", fila))
        if c.get("unir") and not stop.is_set():  # V3c
            try:
                ruta, indice = unir_dia(V, carpeta, dia, list(reg.values()), q)
                if ruta:
                    extra.append(f"{dia:%d-%m-%Y}: video del día listo")
                    if c.get("youtube"):
                        extra.append(f"{dia:%d-%m-%Y}: "
                                     + subir_dia(V, cfg, carpeta, dia, ruta, indice, q, stop))
            except Exception as e:
                extra.append(f"{dia:%d-%m-%Y}: error al unir o subir: {e}")
    q.put(("fin", f"Cotejo terminado: {tot['ok']} con video, {tot['sin']} sin video a esa hora, "
                  f"{tot['err']} con error, {tot['cli']} cliente(s) nuevos en CuentasDark."
                  + ("\n" + "\n".join(extra) if extra else "")))


def cotejar_uno(V, c, dvr, desfase, m, carpeta, tmp, stop):
    t_caja = datetime.strptime(m["hora"], "%Y-%m-%d %H:%M:%S")
    # hora del DVR = hora real + desfase; hora real = hora de la caja - lo que va adelantada
    t_dvr = t_caja - timedelta(seconds=float(c["ajuste_caja"] or 0)) + timedelta(seconds=desfase)
    t_dvr = t_dvr.replace(microsecond=0)
    antes = timedelta(seconds=int(c["antes"]))
    despues = timedelta(seconds=int(c["despues"]))
    ini = t_dvr - antes
    if m["tipo"] == "RECARGA" and m.get("hora_pedido"):
        try:  # desde que se pidió la recarga: el cliente está enfrente
            pedido = datetime.strptime(m["hora_pedido"], "%Y-%m-%d %H:%M:%S") - (t_caja - t_dvr)
            if timedelta(0) < t_dvr - pedido < timedelta(minutes=5):
                ini = min(ini, pedido - timedelta(seconds=5))
        except ValueError:
            pass
    fin = t_dvr + despues
    canal = int(c["canal"])
    base = f"{t_caja:%H%M%S}_{m['tipo']}_{nombre_archivo(m['ref'])}_{m['importe']:.2f}"
    crudo = os.path.join(tmp, uuid.uuid4().hex + ".dav")
    limpio = os.path.join(tmp, uuid.uuid4().hex + ".dav")
    mp4 = os.path.join(tmp, uuid.uuid4().hex + ".mp4")
    res = {"hora_dvr": f"{t_dvr:%H:%M:%S}"}
    try:
        if not bajar_tramo(dvr, canal, ini, fin, crudo, stop):
            res["estado"] = "sin video"
            return res
        buenos, primero, _ = filtrar_tramo(V, crudo, limpio, canal - 1, ini, fin)
        if not buenos or not remux(V, limpio, mp4):
            res["estado"] = "sin video"
            return res
        destino = os.path.join(carpeta, base + ".mp4")
        foto_canal = int(c["canal_foto"])
        area = c.get("area_foto")
        buscar_cara = m["tipo"] == "RECARGA" and foto_canal == canal
        cuadro, cara = hacer_clip(V, mp4, destino, leyenda(m, t_dvr), primero, t_dvr, buscar_cara,
                                  area)
        res.update(estado="ok", clip=destino)
        if m["tipo"] == "RECARGA":
            if foto_canal != canal:
                cuadro, cara = foto_otro_canal(V, dvr, foto_canal, ini, fin, t_dvr, tmp, stop, area)
            if cuadro is not None:
                jpg = recorte_foto(cuadro, cara, area)
                ruta_foto = os.path.join(carpeta, base + "_foto.jpg")
                if jpg:
                    with open(ruta_foto, "wb") as f:
                        f.write(jpg)
                    res["foto"] = ruta_foto
                V.guardar_jpg(os.path.join(carpeta, base + "_cuadro.jpg"), cuadro)
                if c["clientes"]:
                    texto, nuevo = guardar_en_cuentasdark(c, m, jpg)
                    res.update(cliente=texto, cliente_nuevo=nuevo)
        return res
    finally:
        for r in (crudo, limpio, mp4):
            try:
                os.remove(r)
            except OSError:
                pass


def foto_otro_canal(V, dvr, canal, ini, fin, t_dvr, tmp, stop, area=None):
    crudo = os.path.join(tmp, uuid.uuid4().hex + ".dav")
    limpio = os.path.join(tmp, uuid.uuid4().hex + ".dav")
    mp4 = os.path.join(tmp, uuid.uuid4().hex + ".mp4")
    salida = os.path.join(tmp, uuid.uuid4().hex + ".mp4")
    try:
        if not bajar_tramo(dvr, canal, ini, fin, crudo, stop):
            return None, None
        buenos, primero, _ = filtrar_tramo(V, crudo, limpio, canal - 1, ini, fin)
        if not buenos or not remux(V, limpio, mp4):
            return None, None
        return hacer_clip(V, mp4, salida, [], primero, t_dvr, True, area)
    finally:
        for r in (crudo, limpio, mp4, salida):
            try:
                os.remove(r)
            except OSError:
                pass


# ------------------------------------------------------ exportar Excel y PDF
COLUMNAS = [("fecha", "Fecha"), ("hora", "Hora caja"), ("hora_dvr", "Hora DVR"), ("tipo", "Tipo"),
            ("ref", "Ticket"), ("caja", "Caja"), ("importe", "Importe"), ("concepto", "Concepto"),
            ("estado", "Video"), ("cliente", "Cliente / foto"), ("clip", "Clip")]


def exportar_excel(filas, ruta):
    """.xlsx mínimo (sin librerías): una hoja con encabezados en negritas."""
    def col(i):
        s = ""
        i += 1
        while i:
            i, r = divmod(i - 1, 26)
            s = chr(65 + r) + s
        return s

    xml_filas = []
    for r, fila in enumerate([None] + filas, 1):
        celdas = []
        for i, (k, titulo) in enumerate(COLUMNAS):
            ref = f"{col(i)}{r}"
            if fila is None:
                celdas.append(f'<c r="{ref}" t="inlineStr" s="1"><is><t>{escape(titulo)}</t></is></c>')
                continue
            v = fila.get(k, "")
            if k == "importe" and v != "":
                celdas.append(f'<c r="{ref}" s="2"><v>{float(v)}</v></c>')
            else:
                celdas.append(f'<c r="{ref}" t="inlineStr"><is><t xml:space="preserve">'
                              f'{escape(str(v))}</t></is></c>')
        xml_filas.append(f'<row r="{r}">{"".join(celdas)}</row>')
    anchos = [11, 9, 9, 9, 11, 6, 11, 40, 12, 45, 60]
    cols = "".join(f'<col min="{i + 1}" max="{i + 1}" width="{a}" customWidth="1"/>'
                   for i, a in enumerate(anchos))
    hoja = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
            '<sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" '
            'activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>'
            f'<cols>{cols}</cols><sheetData>{"".join(xml_filas)}</sheetData></worksheet>')
    estilos = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
               '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
               '<numFmts count="1"><numFmt numFmtId="164" formatCode="&quot;$&quot;#,##0.00"/></numFmts>'
               '<fonts count="2"><font><sz val="11"/><name val="Calibri"/></font>'
               '<font><b/><sz val="11"/><name val="Calibri"/></font></fonts>'
               '<fills count="2"><fill><patternFill patternType="none"/></fill>'
               '<fill><patternFill patternType="gray125"/></fill></fills>'
               '<borders count="1"><border/></borders>'
               '<cellStyleXfs count="1"><xf/></cellStyleXfs>'
               '<cellXfs count="3"><xf/><xf fontId="1" applyFont="1"/>'
               '<xf numFmtId="164" applyNumberFormat="1"/></cellXfs></styleSheet>')
    with zipfile.ZipFile(ruta, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("[Content_Types].xml",
                   '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
                   '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
                   '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
                   '<Default Extension="xml" ContentType="application/xml"/>'
                   '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
                   '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
                   '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
                   '</Types>')
        z.writestr("_rels/.rels",
                   '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
                   '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
                   '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>'
                   '</Relationships>')
        z.writestr("xl/workbook.xml",
                   '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
                   '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
                   'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
                   '<sheets><sheet name="Cotejo" sheetId="1" r:id="rId1"/></sheets></workbook>')
        z.writestr("xl/_rels/workbook.xml.rels",
                   '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
                   '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
                   '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>'
                   '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>'
                   '</Relationships>')
        z.writestr("xl/worksheets/sheet1.xml", hoja)
        z.writestr("xl/styles.xml", estilos)


def exportar_pdf(filas, ruta, titulo):
    """PDF horizontal tamaño carta (sin librerías), Helvetica con acentos (WinAnsi)."""
    cols = [("fecha", "Fecha", 52), ("hora", "Hora", 42), ("hora_dvr", "DVR", 42),
            ("tipo", "Tipo", 50), ("ref", "Ticket", 56), ("caja", "Caja", 26),
            ("importe", "Importe", 56), ("concepto", "Concepto", 190), ("estado", "Video", 60),
            ("cliente", "Cliente / foto", 158)]
    W, H, M, LH, FS = 792, 612, 30, 13, 7.5

    def enc(s):
        s = str(s).replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")
        return s.encode("cp1252", "replace")

    def corta(s, ancho):
        s = str(s)
        maxc = int(ancho / (FS * 0.56))
        return s if len(s) <= maxc else s[:maxc - 1] + "…"

    paginas, lineas = [], []

    def nueva():
        out = [b"BT /F2 12 Tf", f"{M} {H - M} Td".encode(), b"(" + enc(titulo) + b") Tj ET",
               b"BT /F1 8 Tf", f"{W - M - 120} {H - M} Td".encode(),
               b"(" + enc(f"Hecho {datetime.now():%d-%m-%Y %H:%M}") + b") Tj ET"]
        x = M
        for k, t, a in cols:
            out += [b"BT /F2 8 Tf", f"{x} {H - M - 22} Td".encode(), b"(" + enc(t) + b") Tj ET"]
            x += a
        out.append(f"{M} {H - M - 26} m {W - M} {H - M - 26} l S".encode())
        return out

    actual, y = nueva(), H - M - 38
    total = 0.0
    for f in filas:
        if y < M + 20:
            paginas.append(actual)
            actual, y = nueva(), H - M - 38
        x = M
        for k, t, a in cols:
            v = f.get(k, "")
            if k == "importe" and v != "":
                total += float(v)
                v = dinero(v)
            actual += [f"BT /F1 {FS} Tf".encode(), f"{x} {y} Td".encode(),
                       b"(" + enc(corta(v, a - 3)) + b") Tj ET"]
            x += a
        y -= LH
    actual += [b"BT /F2 9 Tf", f"{M} {max(y - 6, M)} Td".encode(),
               b"(" + enc(f"{len(filas)} movimiento(s)   Total {dinero(total)}") + b") Tj ET"]
    paginas.append(actual)

    objs = [b"<< /Type /Catalog /Pages 2 0 R >>", None,
            b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
            b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>"]
    kids = []
    for p in paginas:
        datos = b"\n".join(p)
        objs.append(b"<< /Length %d >>\nstream\n" % len(datos) + datos + b"\nendstream")
        objs.append(("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 %d %d] /Contents %d 0 R "
                     "/Resources << /Font << /F1 3 0 R /F2 4 0 R >> >> >>"
                     % (W, H, len(objs))).encode())
        kids.append(len(objs))
    objs[1] = ("<< /Type /Pages /Kids [%s] /Count %d >>"
               % (" ".join(f"{k} 0 R" for k in kids), len(kids))).encode()
    out = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
    pos = []
    for i, o in enumerate(objs, 1):
        pos.append(len(out))
        out += b"%d 0 obj\n" % i + o + b"\nendobj\n"
    xref = len(out)
    out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1)
    for p in pos:
        out += b"%010d 00000 n \n" % p
    out += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objs) + 1, xref)
    with open(ruta, "wb") as f:
        f.write(out)


# ------------------------------------------------------------------ ventana
class VentanaCotejo:
    def __init__(self, app, V):
        self.app, self.V = app, V
        self.c = cfg_cotejo(app.cfg)
        self.filas = {}
        self.q = queue.Queue()
        self.stop = threading.Event()
        self.hilo = None
        top = self.top = tk.Toplevel(app.root)
        top.title("Cotejar ventas de TPVDark con el video del DVR")
        alto = min(760, top.winfo_screenheight() - 80)  # V3c: cabe en pantallas de 768 px
        top.geometry(f"1180x{alto}+0+0")
        top.minsize(980, min(560, alto))
        top.transient(app.root)

        marco = ttk.Frame(top)
        marco.pack(side="left", fill="y")
        lienzo = tk.Canvas(marco, highlightthickness=0, borderwidth=0)
        barra_izq = ttk.Scrollbar(marco, orient="vertical", command=lienzo.yview)
        lienzo.configure(yscrollcommand=barra_izq.set)
        barra_izq.pack(side="right", fill="y")
        lienzo.pack(side="left", fill="y")
        izq = ttk.Frame(lienzo, padding=10)
        lienzo.create_window((0, 0), window=izq, anchor="nw")
        izq.bind("<Configure>", lambda _: lienzo.configure(
            scrollregion=lienzo.bbox("all"), width=izq.winfo_reqwidth()))

        def rueda(ev):
            if izq.winfo_reqheight() > lienzo.winfo_height():
                lienzo.yview_scroll(int(-ev.delta / 120), "units")
        lienzo.bind("<Enter>", lambda _: lienzo.bind_all("<MouseWheel>", rueda))
        lienzo.bind("<Leave>", lambda _: lienzo.unbind_all("<MouseWheel>"))
        der = ttk.Frame(top, padding=(0, 10, 10, 10))
        der.pack(side="left", fill="both", expand=True)

        f = ttk.LabelFrame(izq, text=" Fechas ", padding=8)
        f.pack(fill="x")
        self.dias = [datetime.now().date() - timedelta(days=i) for i in range(31)]
        self.lista = tk.Listbox(f, selectmode="multiple", height=8, width=18, exportselection=False)
        nombres = ("lun", "mar", "mié", "jue", "vie", "sáb", "dom")
        for d in self.dias:
            self.lista.insert("end", f"{nombres[d.weekday()]} {d:%d-%m-%Y}")
        self.lista.selection_set(1)
        self.lista.pack(side="left")
        fb = ttk.Frame(f)
        fb.pack(side="left", padx=6, anchor="n")
        ttk.Button(fb, text="Hoy", command=lambda: self._marcar([0])).pack(fill="x")
        ttk.Button(fb, text="Ayer", command=lambda: self._marcar([1])).pack(fill="x", pady=2)
        ttk.Button(fb, text="Últimos 7", command=lambda: self._marcar(range(1, 8))).pack(fill="x")
        ttk.Button(fb, text="Ver guardado", command=self.ver_guardado).pack(fill="x", pady=(10, 0))

        f = ttk.LabelFrame(izq, text=" Qué cotejar ", padding=8)
        f.pack(fill="x", pady=8)
        self.v = {}
        for k, t in (("ventas", "Ventas"), ("recargas", "Recargas (con foto del cliente)"),
                     ("tramites", "Trámites (Novyra y otros)"), ("caja", "Ingresos y retiros de caja")):
            self.v[k] = tk.BooleanVar(value=bool(self.c[k]))
            ttk.Checkbutton(f, text=t, variable=self.v[k]).pack(anchor="w")
        self.v["clientes"] = tk.BooleanVar(value=bool(self.c["clientes"]))
        ttk.Checkbutton(f, text="Dar de alta en CuentasDark los teléfonos\nsin nombre, con su foto",
                        variable=self.v["clientes"]).pack(anchor="w", pady=(4, 0))

        f = ttk.LabelFrame(izq, text=" Foto de las recargas ", padding=8)  # V3c
        f.pack(fill="x", pady=(0, 8))
        ttk.Label(f, text="Canal").grid(row=0, column=0, sticky="w")
        self.v_canal_foto = tk.StringVar(value=str(self.c["canal_foto"]))
        ttk.Combobox(f, textvariable=self.v_canal_foto, values=[str(i) for i in range(1, 9)],
                     state="readonly", width=4).grid(row=0, column=1, sticky="w", padx=4)
        ttk.Button(f, text="Dibujar área...", command=self.dibujar_area).grid(row=0, column=2, padx=4)
        ttk.Button(f, text="Quitar", command=self.quitar_area).grid(row=0, column=3)
        self.lbl_area = ttk.Label(f, foreground="gray", wraplength=300, justify="left")
        self.lbl_area.grid(row=1, column=0, columnspan=4, sticky="w", pady=(4, 0))
        self.area = self.c.get("area_foto")
        self._texto_area()

        f = ttk.LabelFrame(izq, text=" Video del día ", padding=8)  # V3c
        f.pack(fill="x", pady=(0, 8))
        self.v["unir"] = tk.BooleanVar(value=bool(self.c["unir"]))
        self.v["youtube"] = tk.BooleanVar(value=bool(self.c["youtube"]))
        ttk.Checkbutton(f, text="Unir los clips de cada día en un solo video",
                        variable=self.v["unir"]).pack(anchor="w")
        ttk.Checkbutton(f, text="Subirlo a YouTube (playlist del día, 3 intentos)",
                        variable=self.v["youtube"]).pack(anchor="w")

        f = ttk.LabelFrame(izq, text=" Ajustes ", padding=8)
        f.pack(fill="x")
        self.e = {}
        filas = (("canal", "Canal de la caja (video)"),
                 ("antes", "Segundos antes del cobro"), ("despues", "Segundos después"),
                 ("ajuste_caja", "Reloj de la caja adelantado (s)"),
                 ("terminales", "Solo cajas (ej. 1,2; vacío = todas)"),
                 ("minimo", "Importe mínimo ($)"))
        for i, (k, t) in enumerate(filas):
            ttk.Label(f, text=t).grid(row=i, column=0, sticky="w", pady=1)
            self.e[k] = tk.StringVar(value=str(self.c[k]))
            ttk.Entry(f, textvariable=self.e[k], width=10).grid(row=i, column=1, sticky="w", padx=4)
        ttk.Label(f, foreground="gray", wraplength=300, justify="left",
                  text="El reloj del DVR se mide solo en cada corrida. Si el video de una venta "
                       "sale corrido, pon aquí cuántos segundos va adelantada la caja "
                       "(negativo si va atrasada).").grid(row=len(filas), column=0, columnspan=2,
                                                          sticky="w", pady=(4, 0))
        self.v["auto"] = tk.BooleanVar(value=bool(self.c["auto"]))
        ttk.Checkbutton(izq, text="Hacerlo también en la revisión automática diaria (ayer)",
                        variable=self.v["auto"]).pack(anchor="w", pady=(8, 0))
        self.v_rehacer = tk.BooleanVar(value=False)
        ttk.Checkbutton(izq, text="Rehacer los que ya estaban cotejados",
                        variable=self.v_rehacer).pack(anchor="w")

        fb = ttk.Frame(izq)
        fb.pack(fill="x", pady=(10, 0))
        self.btn_ini = ttk.Button(fb, text="▶  COTEJAR", style="Grande.TButton", command=self.iniciar)
        self.btn_ini.pack(side="left", fill="x", expand=True)
        self.btn_det = ttk.Button(fb, text="■  Detener", style="Grande.TButton",
                                  command=self.stop.set, state="disabled")
        self.btn_det.pack(side="left", padx=(6, 0))

        self.barra = ttk.Progressbar(der, maximum=100)
        self.barra.pack(fill="x")
        self.lbl = ttk.Label(der, text="Elige fechas y pulsa COTEJAR.", justify="left")
        self.lbl.pack(anchor="w", pady=(2, 6))
        ff = ttk.Frame(der)
        ff.pack(fill="x", pady=(0, 4))
        ttk.Label(ff, text="Mostrar:").pack(side="left")
        self.v_filtro = tk.StringVar(value="Todos")
        cb = ttk.Combobox(ff, textvariable=self.v_filtro, state="readonly", width=14,
                          values=["Todos", "VENTA", "RECARGA", "TRAMITE", "CAJA", "Sin video"])
        cb.pack(side="left", padx=4)
        cb.bind("<<ComboboxSelected>>", lambda _: self._refrescar())
        ttk.Button(ff, text="Exportar PDF", command=self.pdf).pack(side="right")
        ttk.Button(ff, text="Exportar Excel", command=self.excel).pack(side="right", padx=4)
        ttk.Button(ff, text="Abrir carpeta", command=self.abrir_carpeta).pack(side="right")

        ft = ttk.Frame(der)
        ft.pack(fill="both", expand=True)
        cols = ("fecha", "hora", "hora_dvr", "tipo", "ref", "caja", "importe", "concepto",
                "estado", "cliente")
        anchos = (80, 64, 64, 70, 80, 40, 80, 230, 80, 260)
        self.tabla = ttk.Treeview(ft, columns=cols, show="headings")
        for k, a in zip(cols, anchos):
            self.tabla.heading(k, text=dict(COLUMNAS)[k])
            self.tabla.column(k, width=a, anchor="w" if k in ("concepto", "cliente") else "center")
        sb = ttk.Scrollbar(ft, orient="vertical", command=self.tabla.yview)
        self.tabla.configure(yscrollcommand=sb.set)
        self.tabla.pack(side="left", fill="both", expand=True)
        sb.pack(side="left", fill="y")
        self.tabla.tag_configure("sin", foreground="gray")
        self.tabla.tag_configure("err", foreground="red")
        self.tabla.tag_configure("rec", background="#e8f5e9")
        self.tabla.bind("<Double-1>", self.abrir_clip)
        ttk.Label(der, foreground="gray", text="Doble clic: ver el clip.   Clic derecho: ver la foto.").pack(anchor="w")
        self.tabla.bind("<Button-3>", self.abrir_foto)
        top.after(100, self._cola)
        top.protocol("WM_DELETE_WINDOW", self.cerrar)
        self.ver_guardado()

    # --- fechas
    def _marcar(self, idx):
        self.lista.selection_clear(0, "end")
        for i in idx:
            self.lista.selection_set(i)

    def _elegidas(self):
        return [self.dias[i] for i in self.lista.curselection()]

    # --- ajustes
    def _leer(self):
        try:
            c = dict(self.c)
            for k in ("canal", "antes", "despues"):
                c[k] = int(self.e[k].get())
            c["canal_foto"] = int(self.v_canal_foto.get())
            c["area_foto"] = self.area
            c["ajuste_caja"] = float(self.e["ajuste_caja"].get() or 0)
            c["minimo"] = float(self.e["minimo"].get() or 0)
            c["terminales"] = self.e["terminales"].get().strip()
            if not (1 <= c["canal"] <= 16 and 1 <= c["canal_foto"] <= 16):  # noqa
                raise ValueError
            if c["terminales"] and not lista_terminales(c["terminales"]):
                raise ValueError
        except ValueError:
            messagebox.showwarning("Vigilante", "Revisa los ajustes: canales 1-16, segundos y "
                                   "cajas como números (ej. 1,2).", parent=self.top)
            return False
        for k in ("ventas", "recargas", "tramites", "caja", "clientes", "auto", "unir", "youtube"):
            c[k] = self.v[k].get()
        self.c = c
        self.app.cfg["cotejo"] = c
        self.app._guardar()
        return True

    # --- V3c: área de la foto
    def _texto_area(self):
        if self.area:
            x0, y0, x1, y1 = self.area
            self.lbl_area.config(text=f"Área elegida: {abs(x1 - x0) * 100:.0f}% x {abs(y1 - y0) * 100:.0f}% "
                                      "de la imagen. Busca la cara ahí y, si no la encuentra, guarda "
                                      "esa área como foto.")
        else:
            self.lbl_area.config(text="Sin área: busca la cara en toda la imagen.")

    def quitar_area(self):
        self.area = None
        self._texto_area()

    def dibujar_area(self):
        canal = int(self.v_canal_foto.get())
        try:
            self.top.config(cursor="watch")
            self.top.update()
            img = self.app._foto_dvr(f"ch{canal}")
        except Exception as e:
            messagebox.showerror("Vigilante", f"No se pudo traer la imagen del canal {canal}:\n{e}",
                                 parent=self.top)
            return
        finally:
            self.top.config(cursor="")
        ancho = 960
        alto = int(img.shape[0] * ancho / img.shape[1])
        win = tk.Toplevel(self.top)
        win.title(f"Área de la foto · canal {canal}")
        win.transient(self.top)
        win.grab_set()
        ttk.Label(win, padding=6, text="Arrastra con el ratón un rectángulo donde se ve la cara del "
                                       "cliente (frente a la caja).").pack()
        foto = tk.PhotoImage(data=self.V.a_png_b64(img, ancho))
        cv = tk.Canvas(win, width=ancho, height=alto, cursor="crosshair", highlightthickness=0)
        cv.pack()
        cv.create_image(0, 0, image=foto, anchor="nw")
        cv.foto = foto
        rect = {"id": None, "a": None, "b": None}
        if self.area:
            x0, y0, x1, y1 = self.area
            rect["a"], rect["b"] = (x0 * ancho, y0 * alto), (x1 * ancho, y1 * alto)
            rect["id"] = cv.create_rectangle(*rect["a"], *rect["b"], outline="#00ff00", width=3)

        def bajar(ev):
            rect["a"] = rect["b"] = (ev.x, ev.y)
            if rect["id"]:
                cv.delete(rect["id"])
            rect["id"] = cv.create_rectangle(ev.x, ev.y, ev.x, ev.y, outline="#00ff00", width=3)

        def mover(ev):
            if rect["id"]:
                rect["b"] = (min(max(ev.x, 0), ancho), min(max(ev.y, 0), alto))
                cv.coords(rect["id"], *rect["a"], *rect["b"])
        cv.bind("<ButtonPress-1>", bajar)
        cv.bind("<B1-Motion>", mover)

        def guardar():
            if not rect["id"] or abs(rect["a"][0] - rect["b"][0]) < 20 or abs(rect["a"][1] - rect["b"][1]) < 20:
                messagebox.showwarning("Vigilante", "Dibuja un rectángulo más grande.", parent=win)
                return
            (xa, ya), (xb, yb) = rect["a"], rect["b"]
            self.area = [round(min(xa, xb) / ancho, 4), round(min(ya, yb) / alto, 4),
                         round(max(xa, xb) / ancho, 4), round(max(ya, yb) / alto, 4)]
            self._texto_area()
            self._leer()
            win.destroy()
        fb = ttk.Frame(win, padding=6)
        fb.pack()
        ttk.Button(fb, text="Guardar área", command=guardar).pack(side="left")
        ttk.Button(fb, text="Cancelar", command=win.destroy).pack(side="left", padx=6)

    # --- lista
    def _agregar(self, fila):
        self.filas[fila["clave"] + fila.get("fecha", "")] = fila
        self._refrescar()

    def _refrescar(self):
        filtro = self.v_filtro.get()
        self.tabla.delete(*self.tabla.get_children())
        for k, f in sorted(self.filas.items(), key=lambda kv: (kv[1].get("fecha", ""), kv[1].get("hora", ""))):
            if filtro == "Sin video" and f.get("estado") == "ok":
                continue
            if filtro in TIPOS and f.get("tipo") != filtro:
                continue
            tag = ("sin",) if f.get("estado") == "sin video" else \
                  ("err",) if str(f.get("estado", "")).startswith("error") else \
                  ("rec",) if f.get("tipo") == "RECARGA" else ()
            self.tabla.insert("", "end", iid=k, tags=tag, values=(
                f.get("fecha", ""), f.get("hora", ""), f.get("hora_dvr", ""), f.get("tipo", ""),
                f.get("ref", ""), f.get("caja", ""), dinero(f.get("importe", 0)),
                f.get("concepto", ""), f.get("estado", ""), f.get("cliente", "")))

    def _visibles(self):
        return [self.filas[i] for i in self.tabla.get_children() if i in self.filas]

    def ver_guardado(self):
        self.filas.clear()
        for dia in self._elegidas():
            ruta = os.path.join(self.app.cfg.get("salida") or "", "cotejo", f"{dia:%Y-%m-%d}")
            for f in leer_registro(ruta).values():
                self.filas[f["clave"] + f.get("fecha", "")] = f
        self._refrescar()
        self.lbl.config(text=f"{len(self.filas)} movimiento(s) ya cotejados en las fechas elegidas.")

    def abrir_clip(self, _):
        sel = self.tabla.selection()
        f = self.filas.get(sel[0]) if sel else None
        if f and f.get("clip") and os.path.exists(f["clip"]):
            os.startfile(f["clip"])

    def abrir_foto(self, ev):
        iid = self.tabla.identify_row(ev.y)
        f = self.filas.get(iid)
        if f and f.get("foto") and os.path.exists(f["foto"]):
            os.startfile(f["foto"])

    def abrir_carpeta(self):
        dias = self._elegidas()
        ruta = (carpeta_dia(self.app.cfg, max(dias)) if dias
                else os.path.join(self.app.cfg.get("salida") or "", "cotejo"))
        os.makedirs(ruta, exist_ok=True)
        os.startfile(ruta)

    def _nombre(self, ext):
        dias = self._elegidas()
        txt = f"{min(dias):%Y-%m-%d}_a_{max(dias):%Y-%m-%d}" if dias else f"{datetime.now():%Y-%m-%d}"
        return f"cotejo_{txt}.{ext}"

    def excel(self):
        filas = self._visibles()
        if not filas:
            messagebox.showinfo("Vigilante", "No hay nada en la lista.", parent=self.top)
            return
        ruta = filedialog.asksaveasfilename(parent=self.top, defaultextension=".xlsx",
                                            initialfile=self._nombre("xlsx"),
                                            filetypes=[("Excel", "*.xlsx")])
        if ruta:
            exportar_excel(filas, ruta)
            os.startfile(ruta)

    def pdf(self):
        filas = self._visibles()
        if not filas:
            messagebox.showinfo("Vigilante", "No hay nada en la lista.", parent=self.top)
            return
        ruta = filedialog.asksaveasfilename(parent=self.top, defaultextension=".pdf",
                                            initialfile=self._nombre("pdf"),
                                            filetypes=[("PDF", "*.pdf")])
        if ruta:
            dias = self._elegidas()
            titulo = "Cotejo TPVDark vs video" + (f"  {min(dias):%d-%m-%Y} a {max(dias):%d-%m-%Y}"
                                                   if dias else "")
            exportar_pdf(filas, ruta, titulo)
            os.startfile(ruta)

    # --- trabajo
    def iniciar(self):
        if not self._leer():
            return
        dias = self._elegidas()
        if not dias:
            messagebox.showwarning("Vigilante", "Elige al menos una fecha.", parent=self.top)
            return
        if self.app.hilo and self.app.hilo.is_alive():
            messagebox.showwarning("Vigilante", "Espera a que termine el trabajo de la ventana "
                                   "principal (usa el mismo DVR).", parent=self.top)
            return
        self.ver_guardado()
        self.stop.clear()
        self.btn_ini.config(state="disabled")
        self.btn_det.config(state="normal")
        cfg = dict(self.app.cfg)
        rehacer = self.v_rehacer.get()

        def correr():
            try:
                ejecutar(self.V, cfg, self.q, self.stop, dias, rehacer)
            except Exception as e:
                self.q.put(("fin", f"Error: {e}"))
        self.hilo = threading.Thread(target=correr, daemon=True)
        self.hilo.start()

    def _cola(self):
        try:
            while True:
                tipo, *d = self.q.get_nowait()
                if tipo == "estado":
                    self.lbl.config(text=d[0])
                elif tipo == "progreso":
                    self.barra.config(value=d[0] * 100)
                    self.lbl.config(text=d[1])
                elif tipo == "cotejo":
                    self._agregar(d[0])
                elif tipo == "fin":
                    self.barra.config(value=0)
                    self.lbl.config(text=d[0])
                    self.btn_ini.config(state="normal")
                    self.btn_det.config(state="disabled")
                    # V3b: misma casilla de la ventana principal
                    if getattr(self.app, "v_apagar", None) and self.app.v_apagar.get() \
                            and not self.stop.is_set():
                        self.V.aviso_apagado(self.app.root)
        except queue.Empty:
            pass
        if self.top.winfo_exists():
            self.top.after(100, self._cola)

    def cerrar(self):
        self.stop.set()
        try:
            self._leer()
        except Exception:
            pass
        self.top.destroy()
