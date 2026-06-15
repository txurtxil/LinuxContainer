import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../models/network_result.dart';
import 'proot_service.dart';

class NetworkService {
  final ProotService _proot = ProotService();

  String _output = '';
  bool _running = false;

  String get output => _output;
  bool get running => _running;

  /// Ping via toybox (disponible en /system/bin)
  Future<NetworkResult> ping(String host, {int count = 4}) async {
    _running = true;
    final start = DateTime.now();
    final output = await _proot.runCommand(
      'ping -c $count "$host" 2>&1 || echo "ping no disponible"',
      timeout: const Duration(seconds: 30),
    );
    final duration = DateTime.now().difference(start);
    _output = output;
    _running = false;
    return NetworkResult(
      command: 'ping -c $count $host',
      output: output,
      exitCode: 0,
      duration: duration,
    );
  }

  /// HTTP request via Dart HttpClient (alternativa a curl)
  Future<NetworkResult> curl(String url) async {
    _running = true;
    final start = DateTime.now();
    String output;

    try {
      final client = HttpClient();
      try {
        final req = await client.getUrl(Uri.parse(url));
        final resp = await req.close();
        final body = await resp.transform(utf8.decoder).join();
        output = 'HTTP ${resp.statusCode} ${resp.reasonPhrase}\n';
        output += 'Headers:\n';
        resp.headers.forEach((name, values) {
          output += '  $name: ${values.join(", ")}\n';
        });
        output += '\nBody (primeros 2000 chars):\n';
        output += body.length > 2000 ? '${body.substring(0, 2000)}...' : body;
      } finally {
        client.close();
      }
    } catch (e) {
      output = 'Error: $e';
    }

    final duration = DateTime.now().difference(start);
    _output = output;
    _running = false;
    return NetworkResult(
      command: 'curl $url (Dart)',
      output: output,
      exitCode: 0,
      duration: duration,
    );
  }

  /// Traceroute via toybox
  Future<NetworkResult> traceroute(String host) async {
    _running = true;
    final start = DateTime.now();
    final output = await _proot.runCommand(
      'traceroute -m 15 "$host" 2>&1 || '
      'tracepath "$host" 2>&1 || '
      'echo "traceroute no disponible en toybox"',
      timeout: const Duration(seconds: 60),
    );
    final duration = DateTime.now().difference(start);
    _output = output;
    _running = false;
    return NetworkResult(
      command: 'traceroute $host',
      output: output,
      exitCode: 0,
      duration: duration,
    );
  }

  /// Netstat via toybox
  Future<NetworkResult> netstat() async {
    _running = true;
    final start = DateTime.now();
    final output = await _proot.runCommand(
      'netstat -tulanp 2>&1 || '
      'ss -tulanp 2>&1 || '
      'echo "netstat no disponible"',
      timeout: const Duration(seconds: 15),
    );
    final duration = DateTime.now().difference(start);
    _output = output;
    _running = false;
    return NetworkResult(
      command: 'netstat -tulanp',
      output: output,
      exitCode: 0,
      duration: duration,
    );
  }

  /// DNS lookup via toybox (nslookup/dig)
  Future<NetworkResult> dig(String domain) async {
    _running = true;
    final start = DateTime.now();
    final output = await _proot.runCommand(
      'nslookup "$domain" 2>&1 || '
      'dig "$domain" 2>&1 || '
      'echo "nslookup no disponible"',
      timeout: const Duration(seconds: 20),
    );
    final duration = DateTime.now().difference(start);
    _output = output;
    _running = false;
    return NetworkResult(
      command: 'nslookup $domain',
      output: output,
      exitCode: 0,
      duration: duration,
    );
  }

  /// DNS check via Dart
  Future<NetworkResult> dnsLookup(String domain) async {
    _running = true;
    final start = DateTime.now();
    String output;
    try {
      final addresses = await InternetAddress.lookup(domain);
      output = '${addresses.length} direcciones encontradas:\n';
      for (final addr in addresses) {
        output += '  ${addr.address} (${addr.type.name})\n';
      }
    } catch (e) {
      output = 'Error DNS: $e';
    }
    final duration = DateTime.now().difference(start);
    _output = output;
    _running = false;
    return NetworkResult(
      command: 'dns_lookup $domain (Dart)',
      output: output,
      exitCode: 0,
      duration: duration,
    );
  }
}
