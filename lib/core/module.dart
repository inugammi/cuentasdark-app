import 'package:flutter/material.dart';

/// Un módulo es una sección de la app. Para añadir uno nuevo:
/// 1. Crea una carpeta en `lib/modules/<nombre>/` con una clase que extienda AppModule.
/// 2. Regístrala en la lista `modules` de lib/modules/registry.dart.
abstract class AppModule {
  String get id;
  String get title;
  IconData get icon;

  /// Si es false no se puede desactivar desde Ajustes.
  bool get optional => true;

  Widget build(BuildContext context);

  /// Se llama una vez al iniciar la app.
  Future<void> init() async {}
}

/// Avisa a todas las pantallas que cambiaron los datos (después de sincronizar o importar).
final cambiosDatos = ValueNotifier<int>(0);
void avisarCambios() => cambiosDatos.value++;
