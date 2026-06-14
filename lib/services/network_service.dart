import '../models/network_result.dart';
import 'proot_service.dart';

class NetworkService {
  final ProotService _proot = ProotService();

  String _output = '';
  bool _running = false;

  String get output => _output;
  bool get running => _running;

  Future<NetworkResult> ping(String host, {int count = 4}) async {
    _running = true;
    final start = DateTime.now();
    final output = await _proot.runCommand(
      'ping -c $count "$host" 2>&1 || true',
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

  Future<NetworkResult> curl(String url) async {
    _running = true;
    final start = DateTime.now();
    final output = await _proot.runCommand(
      'curl -sI "$url" 2>&1 || true',
      timeout: const Duration(seconds: 30),
    );
    final duration = DateTime.now().difference(start);
    _output = output;
    _running = false;
    return NetworkResult(
      command: 'curl -sI $url',
      output: output,
      exitCode: 0,
      duration: duration,
    );
  }

  Future<NetworkResult> traceroute(String host) async {
    _running = true;
    final start = DateTime.now();
    final output = await _proot.runCommand(
      'traceroute -m 15 "$host" 2>&1 || tracepath "$host" 2>&1 || echo "traceroute no disponible"',
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

  Future<NetworkResult> netstat() async {
    _running = true;
    final start = DateTime.now();
    final output = await _proot.runCommand(
      'netstat -tulanp 2>&1 || ss -tulanp 2>&1 || echo "netstat no disponible"',
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

  Future<NetworkResult> dig(String domain) async {
    _running = true;
    final start = DateTime.now();
    final output = await _proot.runCommand(
      'dig "$domain" 2>&1 || nslookup "$domain" 2>&1 || echo "dig no disponible"',
      timeout: const Duration(seconds: 20),
    );
    final duration = DateTime.now().difference(start);
    _output = output;
    _running = false;
    return NetworkResult(
      command: 'dig $domain',
      output: output,
      exitCode: 0,
      duration: duration,
    );
  }
}
