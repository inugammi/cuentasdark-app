import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../core/module.dart';
import '../core/settings.dart';
import 'articulos/articulos_module.dart';
import 'clientes/clientes_module.dart';
import 'cuentas/cuentas_module.dart';
import 'graficas/graficas_module.dart';
import 'recargas/recargas_module.dart';
import 'settings/settings_module.dart';
import 'tpvdark/tpvdark_module.dart';

/// Lista de módulos de la app. Para agregar uno nuevo, créalo y añádelo aquí.
/// Los primeros 4 activos aparecen en la barra inferior; el resto en "Más".
final List<AppModule> modules = [
  CuentasModule(),
  RecargasModule(),
  ClientesModule(),
  ArticulosModule(),
  GraficasModule(),
  TpvdarkModule(),
  SettingsModule(),
];

List<AppModule> enabledModules(BuildContext context) {
  final off = context.read<Settings>().disabledModules;
  return modules.where((m) => !m.optional || !off.contains(m.id)).toList();
}
