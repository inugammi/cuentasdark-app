import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';

import 'core/db.dart';
import 'core/module.dart';
import 'core/revision.dart';
import 'core/settings.dart';
import 'core/tae.dart';
import 'core/tpv.dart';
import 'modules/registry.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = Settings();
  await Future.wait([settings.load(), Db.open(), initializeDateFormatting('es')]);
  for (final m in modules) {
    await m.init();
  }
  runApp(ChangeNotifierProvider.value(value: settings, child: const App()));
}

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext context) {
    final s = context.watch<Settings>();
    return MaterialApp(
      title: 'Cuentas Dark',
      debugShowCheckedModeBanner: false,
      theme: s.theme(Brightness.light),
      darkTheme: s.theme(Brightness.dark),
      themeMode: s.mode,
      locale: const Locale('es', 'MX'),
      supportedLocales: const [Locale('es', 'MX'), Locale('es'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(s.textScale)),
        child: child!,
      ),
      home: const Home(),
    );
  }
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  int index = 0;
  String? cargando = 'Preparando tus datos…';

  @override
  void initState() {
    super.initState();
    _arranque();
  }

  /// Primera vez: carga el histórico de los Excel. Cada día: trae lo nuevo de TPVDark.
  Future<void> _arranque() async {
    try {
      await Db.importarHistorico();
      await Vigilante.limpiar();
    } catch (e) {
      debugPrint('$e');
    }
    if (!mounted) return;
    setState(() => cargando = null);
    avisarCambios();
    final s = context.read<Settings>();
    final t = Tpv(s);
    if (s.autoSync && t.configurado) {
      try {
        await Db.setKv('tpvAviso', await t.sincronizar());
        avisarCambios();
      } catch (e) {
        await Db.setKv('tpvAviso', '⚠ $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    context.watch<Settings>();
    if (cargando != null) {
      return Scaffold(
          body: Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
        const CircularProgressIndicator(),
        const SizedBox(height: 16),
        Text(cargando!),
        const Text('La primera vez carga tus Excel desde 2005.'),
      ])));
    }
    final all = enabledModules(context);
    final primary = all.take(all.length > 4 ? 4 : all.length).toList();
    final more = all.skip(primary.length).toList();
    final i = index.clamp(0, primary.length + (more.isEmpty ? 0 : 1) - 1);
    return Scaffold(
      body: Stack(children: [
        Positioned.fill(child: i < primary.length ? primary[i].build(context) : _More(more)),
        const Positioned(left: 0, top: 0, child: TaeAuto()),
      ]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: i,
        onDestinationSelected: (v) => setState(() => index = v),
        destinations: [
          for (final m in primary) NavigationDestination(icon: Icon(m.icon), label: m.title),
          if (more.isNotEmpty) const NavigationDestination(icon: Icon(Icons.apps), label: 'Más'),
        ],
      ),
    );
  }
}

class _More extends StatelessWidget {
  final List<AppModule> mods;
  const _More(this.mods);
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Más')),
        body: ListView(children: [
          for (final m in mods)
            ListTile(
              leading: Icon(m.icon),
              title: Text(m.title),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: m.build)),
            ),
        ]),
      );
}
