import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

const palettes = <String, Color>{
  'Azul TPVDark': Color(0xFF007ACC),
  'Verde': Color(0xFF2EA043),
  'Naranja': Color(0xFFD67800),
  'Rojo': Color(0xFFC42B1C),
  'Morado': Color(0xFF6A1B9A),
  'Turquesa': Color(0xFF00897B),
  'Gris acero': Color(0xFF546E7A),
};

/// Preferencias de la app (apariencia, conexión a TPVDark/Supabase, TAE Pocket, reglas de cuentas).
class Settings extends ChangeNotifier {
  late SharedPreferences _p;

  Future<void> load() async => _p = await SharedPreferences.getInstance();

  T _get<T>(String k, T def) => (_p.get(k) as T?) ?? def;
  Future<void> set(String k, Object v) async {
    if (v is int) await _p.setInt(k, v);
    if (v is double) await _p.setDouble(k, v);
    if (v is bool) await _p.setBool(k, v);
    if (v is String) await _p.setString(k, v);
    if (v is List<String>) await _p.setStringList(k, v);
    notifyListeners();
  }

  // Apariencia
  int get seed => _get('seed', palettes.values.first.toARGB32());
  double get textScale => _get('textScale', 1.0);
  String get themeMode => _get('themeMode', 'dark'); // system | light | dark
  bool get amoled => _get('amoled', false);

  // TPVDark (misma cuenta de Supabase que la caja y TPVDarkMovil)
  String get sbUrl => _get('sbUrl', '');
  String get sbKey => _get('sbKey', '');
  String get sbEmail => _get('sbEmail', '');
  String get sbPass => _get('sbPass', '');
  bool get autoSync => _get('autoSync', true);
  int get diasArticulos => _get('diasArticulos', 90);

  // TAE Pocket
  String get taeUrl => _get('taeUrl', 'https://taepocketplus.com/inicio.php');
  String get taeHistorial => _get('taeHistorial', '');
  bool get taeAuto => _get('taeAuto', true);

  // Reglas de cuentas (como en tus Excel)
  double get cargoRecarga => _get('cargoRecarga', 1.0); // $ extra que cobras por recarga (L = Total día + Núm rec)
  double get bonoAbono => _get('bonoAbono', 7.4); // % que te bonifica TAE Pocket al abonar saldo
  bool get diferenciaConRecargas => _get('diferenciaConRecargas', true);

  // Módulos desactivados
  List<String> get disabledModules => _p.getStringList('disabledModules') ?? const [];

  ThemeMode get mode => switch (themeMode) {
        'light' => ThemeMode.light,
        'system' => ThemeMode.system,
        _ => ThemeMode.dark,
      };

  ThemeData theme(Brightness b) => ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Color(seed), brightness: b),
        useMaterial3: true,
        scaffoldBackgroundColor: b == Brightness.dark && amoled ? Colors.black : null,
        inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder(), isDense: true),
      );
}

final _dinero = NumberFormat.currency(locale: 'es_MX', symbol: '\$', decimalDigits: 2);
final _dineroCorto = NumberFormat.currency(locale: 'es_MX', symbol: '\$', decimalDigits: 0);
String money(num v) => (v % 1 == 0 ? _dineroCorto : _dinero).format(v);
String entero(num v) => NumberFormat.decimalPattern('es_MX').format(v);
