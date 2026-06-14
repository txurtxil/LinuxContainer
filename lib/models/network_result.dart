class NetworkResult {
  final String command;
  final String output;
  final int exitCode;
  final Duration duration;

  NetworkResult({
    required this.command,
    required this.output,
    required this.exitCode,
    required this.duration,
  });

  bool get success => exitCode == 0;

  String get durationFormatted {
    if (duration.inSeconds < 60) {
      return '${duration.inSeconds}s';
    }
    return '${duration.inMinutes}m ${duration.inSeconds % 60}s';
  }
}
