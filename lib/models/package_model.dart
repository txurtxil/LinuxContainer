class PackageModel {
  final String name;
  final String version;
  final String description;
  final bool installed;

  PackageModel({
    required this.name,
    required this.version,
    required this.description,
    required this.installed,
  });

  factory PackageModel.fromAptLine(String line) {
    final name = RegExp(r'^([a-zA-Z0-9+.-]+)').firstMatch(line)?.group(1) ?? 'unknown';
    final description = line.length > 60 ? '${line.substring(0, 60)}...' : line;
    return PackageModel(
      name: name,
      version: '',
      description: description,
      installed: false,
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'version': version,
    'description': description,
    'installed': installed,
  };
}
