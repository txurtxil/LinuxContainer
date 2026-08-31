// lib/src/ssh/ssh_credentials_store.dart
//
// Contrasenas de los hosts SSH, en almacenamiento CIFRADO del sistema
// (Keystore de Android via flutter_secure_storage) -- deliberadamente
// separado de ssh_hosts.json, que es texto plano y podria acabar
// exportado o compartido algun dia. Una contrasena real no tiene sitio
// ahi al lado del nombre del host.
//
// Alcance real, para no prometer de mas: esto rellena la contrasena
// automaticamente en las conexiones SFTP (dartssh2, que corre dentro del
// propio proceso de la app y acepta la contrasena por codigo via
// onPasswordRequest). NO llega todavia a las sesiones SSH de terminal,
// que tiran del binario ssh real dentro de proot -- ahi la contrasena
// se sigue tecleando en el propio pty, como una sesion ssh normal.
// Automatizar eso necesitaria sshpass (u otro mecanismo) dentro del
// rootfs, que es un paso aparte.

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SshCredentialsStore {
  // v11.0.0 retiro por completo encryptedSharedPreferences (dependia de
  // Jetpack Security, que Google dejo de mantener). El cifrado por
  // defecto de esta version (AES-GCM con envoltura RSA-OAEP) ya es la
  // opcion buena, asi que no hace falta pasar ninguna opcion especial.
  static const _storage = FlutterSecureStorage();

  static String _keyFor(String hostId) => 'ssh_password_$hostId';

  static Future<void> savePassword(String hostId, String password) async {
    if (password.isEmpty) {
      await _storage.delete(key: _keyFor(hostId));
      return;
    }
    await _storage.write(key: _keyFor(hostId), value: password);
  }

  static Future<String?> readPassword(String hostId) async {
    try {
      return await _storage.read(key: _keyFor(hostId));
    } catch (_) {
      return null;
    }
  }

  static Future<void> deletePassword(String hostId) async {
    try {
      await _storage.delete(key: _keyFor(hostId));
    } catch (_) {}
  }

  static Future<bool> hasPassword(String hostId) async {
    final p = await readPassword(hostId);
    return p != null && p.isNotEmpty;
  }
}
