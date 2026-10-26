import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'calc.dart';
import 'db.dart';
import 'module.dart';
import 'revision.dart';
import 'settings.dart';
import 'ui.dart';

/// JavaScript que junta el texto de cada celda de todas las tablas de la página (y de sus marcos).
const _jsTablas = r'''
(function(){
  var out=[];
  function leer(doc){
    try{
      doc.querySelectorAll('tr').forEach(function(tr){
        var c=[]; tr.querySelectorAll('td,th').forEach(function(td){c.push((td.innerText||'').trim());});
        if(c.length>=4) out.push(c);
      });
      doc.querySelectorAll('iframe').forEach(function(f){ try{ leer(f.contentDocument); }catch(e){} });
    }catch(e){}
  }
  leer(document);
  var login = !!document.querySelector('input[type=password]');
  return JSON.stringify({filas:out, login:login, url:location.href});
})();
''';

/// Lee la tabla de historial que está abierta en el WebView y guarda las recargas nuevas.
Future<(int nuevas, int leidas, bool login)> leerTae(WebViewController c) async {
  var r = await c.runJavaScriptReturningResult(_jsTablas);
  var t = r is String ? r : '$r';
  if (t.startsWith('"')) t = jsonDecode(t) as String;
  final j = jsonDecode(t) as Map<String, dynamic>;
  final filas = (j['filas'] as List).map((e) => (e as List).map((x) => '$x').toList()).toList();
  final recs = [for (final f in filas) ?filaRecarga(f)];
  final nuevas = await Db.guardarRecargas(recs, 'tae');
  if (recs.isNotEmpty) {
    await Db.setKv('taeUltima', iso(DateTime.now()));
    await Vigilante.limpiar();
    avisarCambios();
  }
  return (nuevas, recs.length, j['login'] == true);
}

/// Pantalla con la página de TAE Pocket adentro de la app.
/// Entras una vez con tu usuario (la sesión se queda guardada), abres el historial
/// y tocas "Leer". Con "Usar para cada día" la app lo lee sola cada vez que la abres.
class TaePage extends StatefulWidget {
  const TaePage({super.key});
  @override
  State<TaePage> createState() => _TaePageState();
}

class _TaePageState extends State<TaePage> {
  late final WebViewController c;
  var cargando = true;

  @override
  void initState() {
    super.initState();
    final s = context.read<Settings>();
    c = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (_) => setState(() => cargando = true),
        onPageFinished: (_) => setState(() => cargando = false),
      ))
      ..loadRequest(Uri.parse(s.taeHistorial.isNotEmpty ? s.taeHistorial : s.taeUrl));
  }

  Future<void> _leer() async {
    try {
      final (nuevas, leidas, login) = await leerTae(c);
      if (!mounted) return;
      if (leidas == 0) {
        toast(context, login ? 'Primero entra con tu usuario de TAE Pocket.' : 'No vi recargas en esta página. Abre el historial o reporte de ventas.');
      } else {
        toast(context, 'Leí $leidas recargas: $nuevas nuevas.');
      }
    } catch (e) {
      if (mounted) toast(context, 'No pude leer la página: $e');
    }
  }

  Future<void> _fijar() async {
    final url = await c.currentUrl();
    if (url == null || !mounted) return;
    await context.read<Settings>().set('taeHistorial', url);
    if (mounted) toast(context, 'Listo: esta página se leerá sola cada día.');
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('TAE Pocket'),
          actions: [
            IconButton(tooltip: 'Atrás', icon: const Icon(Icons.arrow_back_ios_new), onPressed: () => c.goBack()),
            IconButton(tooltip: 'Recargar', icon: const Icon(Icons.refresh), onPressed: () => c.reload()),
            PopupMenuButton<String>(
              onSelected: (v) => v == 'fijar' ? _fijar() : c.loadRequest(Uri.parse(context.read<Settings>().taeUrl)),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'fijar', child: Text('Usar esta página para leer cada día')),
                PopupMenuItem(value: 'inicio', child: Text('Ir al inicio de TAE Pocket')),
              ],
            ),
          ],
          bottom: cargando ? const PreferredSize(preferredSize: Size.fromHeight(3), child: LinearProgressIndicator()) : null,
        ),
        body: WebViewWidget(controller: c),
        floatingActionButton: FloatingActionButton.extended(
            onPressed: _leer, icon: const Icon(Icons.download), label: const Text('Leer recargas')),
      );
}

/// WebView invisible que lee el historial guardado una vez al día cuando abres la app.
class TaeAuto extends StatefulWidget {
  const TaeAuto({super.key});
  @override
  State<TaeAuto> createState() => _TaeAutoState();
}

class _TaeAutoState extends State<TaeAuto> {
  WebViewController? c;

  @override
  void initState() {
    super.initState();
    _quizas();
  }

  Future<void> _quizas() async {
    final s = context.read<Settings>();
    if (!s.taeAuto || s.taeHistorial.isEmpty) return;
    if (await Db.kv('taeUltima') == iso(DateTime.now()) && await Db.kv('taeAuto') == iso(DateTime.now())) return;
    final ctl = WebViewController()..setJavaScriptMode(JavaScriptMode.unrestricted);
    ctl.setNavigationDelegate(NavigationDelegate(onPageFinished: (_) async {
      await Future.delayed(const Duration(seconds: 4));
      try {
        final (nuevas, leidas, login) = await leerTae(ctl);
        await Db.setKv('taeAuto', iso(DateTime.now()));
        await Db.setKv('taeAviso', login && leidas == 0
            ? 'TAE Pocket pide que entres otra vez: abre Recargas > TAE Pocket.'
            : 'TAE Pocket leído hoy: $leidas recargas, $nuevas nuevas.');
        avisarCambios();
      } catch (_) {}
      if (mounted) setState(() => c = null);
    }));
    await ctl.loadRequest(Uri.parse(s.taeHistorial));
    if (mounted) setState(() => c = ctl);
  }

  @override
  Widget build(BuildContext context) =>
      c == null ? const SizedBox.shrink() : SizedBox(width: 1, height: 1, child: WebViewWidget(controller: c!));
}
