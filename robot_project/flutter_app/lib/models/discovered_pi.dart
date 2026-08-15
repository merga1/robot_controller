class DiscoveredPi {
  final String username;
  final String hostname;
  final String ip;
  final int apiPort;
  final String source;

  const DiscoveredPi({
    required this.username,
    required this.hostname,
    required this.ip,
    this.apiPort = 8000,
    required this.source,
  });

  String get label => '$username @ $ip ($hostname)';

  @override
  bool operator ==(Object other) =>
      other is DiscoveredPi && other.ip == ip && other.username == username;

  @override
  int get hashCode => Object.hash(ip, username);
}
