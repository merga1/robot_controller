import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:multicast_dns/multicast_dns.dart';

import '../models/discovered_pi.dart';

/// Finds the Raspberry Pi (user delv or abpi) on the same Wi‑Fi.
/// Uses UDP beacon + mDNS + HTTP /health subnet scan.
class PiDiscoveryService {
  static const _serviceType = '_robotcontrol._tcp.local';
  static const _udpPort = 9999;
  static const _discoverKey = 'robot-control';
  static const defaultApiPort = 8000;

  /// Preferred default when username is unknown (HTTP scan fallback).
  static const defaultPiUsername = 'delv';

  /// Allowed SSH / Pi OS users on this robot.
  static const allowedPiUsers = {'delv', 'abpi'};

  static bool isAllowedPiUser(String user) =>
      allowedPiUsers.contains(user.trim().toLowerCase());

  static String normalizePiUser(String user) {
    final u = user.trim().toLowerCase();
    if (isAllowedPiUser(u)) return u;
    return defaultPiUsername;
  }

  static Map<String, String> parseTxtProperties(String raw) {
    final out = <String, String>{};
    for (final chunk in raw.split(RegExp(r'[\x00]+'))) {
      for (final token in chunk.split(RegExp(r'\s+'))) {
        if (token.isEmpty) continue;
        final eq = token.indexOf('=');
        if (eq <= 0) continue;
        out[token.substring(0, eq)] = token.substring(eq + 1);
      }
    }
    return out;
  }

  void _upsert(Map<String, DiscoveredPi> found, DiscoveredPi pi) {
    if (!isAllowedPiUser(pi.username)) return;
    final existing = found[pi.ip];
    if (existing == null) {
      found[pi.ip] = pi;
      return;
    }
    // Prefer richer identity (known user from beacon) over http-scan guess.
    const rank = {
      'udp-reply': 5,
      'udp': 4,
      'mdns': 3,
      'http-scan': 2,
      'manual': 0,
    };
    final existingRank = rank[existing.source] ?? 0;
    final newRank = rank[pi.source] ?? 0;
    if (newRank > existingRank) {
      found[pi.ip] = pi;
      return;
    }
    // Same rank: keep non-default username if new one is more specific.
    if (newRank == existingRank &&
        existing.username == defaultPiUsername &&
        pi.username != defaultPiUsername) {
      found[pi.ip] = pi;
    }
  }

  Future<String?> tabletIp() => _tabletIp();

  Future<String?> subnetPrefix() async {
    final ip = await _tabletIp();
    if (ip == null) return null;
    final parts = ip.split('.');
    if (parts.length != 4) return null;
    return '${parts[0]}.${parts[1]}.${parts[2]}';
  }

  /// Prefer Wi‑Fi LAN addresses; skip VPN / cellular / link-local.
  Future<String?> _tabletIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      );
      final scored = <({String ip, int score})>[];
      for (final iface in interfaces) {
        final name = iface.name.toLowerCase();
        var ifaceScore = 0;
        if (name.contains('wlan') ||
            name.contains('wifi') ||
            name.contains('en0') ||
            name.contains('eth')) {
          ifaceScore += 50;
        }
        if (name.contains('tun') ||
            name.contains('ppp') ||
            name.contains('rmnet') ||
            name.contains('ccmni') ||
            name.contains('vpn')) {
          ifaceScore -= 80;
        }
        for (final addr in iface.addresses) {
          if (addr.isLoopback || addr.type != InternetAddressType.IPv4) continue;
          final ip = addr.address;
          var score = ifaceScore + _privateLanScore(ip);
          if (score > 0) scored.add((ip: ip, score: score));
        }
      }
      if (scored.isEmpty) return null;
      scored.sort((a, b) => b.score.compareTo(a.score));
      return scored.first.ip;
    } catch (_) {}
    return null;
  }

  int _privateLanScore(String ip) {
    final p = ip.split('.');
    if (p.length != 4) return -100;
    final a = int.tryParse(p[0]) ?? 0;
    final b = int.tryParse(p[1]) ?? 0;
    // Typical home/robot Wi‑Fi
    if (a == 192 && b == 168) return 40;
    if (a == 10) return 30;
    if (a == 172 && b >= 16 && b <= 31) return 20;
    // Android USB tethering / hotspot — usable but lower priority
    if (a == 192 && b == 0) return 5;
    return -50;
  }

  String _subnetBroadcast(String ip) {
    final parts = ip.split('.');
    if (parts.length == 4) {
      return '${parts[0]}.${parts[1]}.${parts[2]}.255';
    }
    return '255.255.255.255';
  }

  DiscoveredPi? _piFromJson(
    Map<String, dynamic> json, {
    required String source,
    String? fallbackIp,
  }) {
    if (json['service']?.toString() != _discoverKey) return null;
    // Prefer the address we actually reached (UDP packet source / HTTP probe IP).
    // The Pi payload "ip" can be wrong when multiple NICs exist (eth0 vs wlan0).
    final payloadIp = json['ip']?.toString().trim();
    final routeIp = fallbackIp?.trim();
    String? ip;
    if (routeIp != null && routeIp.isNotEmpty) {
      ip = routeIp;
    } else if (payloadIp != null && payloadIp.isNotEmpty) {
      ip = payloadIp;
    }
    if (ip == null || ip.isEmpty) return null;
    final user = normalizePiUser(
      (json['user']?.toString() ?? defaultPiUsername).split(RegExp(r'\s+')).first,
    );
    if (!isAllowedPiUser(user)) return null;
    return DiscoveredPi(
      username: user,
      hostname: json['host']?.toString() ?? '$user-pi',
      ip: ip,
      apiPort: int.tryParse(json['api_port']?.toString() ?? '') ?? defaultApiPort,
      source: source,
    );
  }

  static Future<bool> probeApiHealth(
    String ip, {
    int port = defaultApiPort,
    Duration timeout = const Duration(seconds: 2),
  }) async {
    final info = await probeApiInfo(ip, port: port, timeout: timeout);
    return info != null;
  }

  /// Returns health JSON extras (user/host) when backend is up.
  static Future<Map<String, dynamic>?> probeApiInfo(
    String ip, {
    int port = defaultApiPort,
    Duration timeout = const Duration(seconds: 2),
  }) async {
    try {
      final res = await http
          .get(Uri.parse('http://$ip:$port/health'))
          .timeout(timeout);
      if (res.statusCode != 200) return null;
      try {
        final body = jsonDecode(res.body);
        if (body is Map) {
          final map = Map<String, dynamic>.from(body);
          // Must be our robot API — ignore random HTTP servers on :8000.
          if (map['service']?.toString() == 'robot-control' ||
              map['ok'] == true) {
            map['_probe_ip'] = ip;
            return map;
          }
        }
      } catch (_) {}
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<List<DiscoveredPi>> discover({
    Duration timeout = const Duration(seconds: 14),
    bool includeHttpScan = true,
  }) async {
    final found = <String, DiscoveredPi>{};
    await Future.wait([
      _discoverUdp(found, timeout),
      _discoverMdns(found, const Duration(seconds: 5)),
    ]);
    if (includeHttpScan) {
      final prefixes = await _scanPrefixes();
      for (final prefix in prefixes) {
        await _discoverHttpPrefix(found, prefix);
        if (found.isNotEmpty) {
          final localIp = await _tabletIp();
          final tabletPrefix = localIp != null && localIp.split('.').length == 4
              ? '${localIp.split('.')[0]}.${localIp.split('.')[1]}.${localIp.split('.')[2]}'
              : null;
          if (tabletPrefix != null &&
              found.values.any((d) => _ipOnPrefix(d.ip, tabletPrefix))) {
            break;
          }
        }
      }
    }
    final localIp = await _tabletIp();
    final subnetPrefix = localIp != null && localIp.split('.').length == 4
        ? '${localIp.split('.')[0]}.${localIp.split('.')[1]}.${localIp.split('.')[2]}'
        : null;
    bool sameSubnet(DiscoveredPi d) {
      if (subnetPrefix == null) return false;
      final p = d.ip.split('.');
      if (p.length != 4) return false;
      return '${p[0]}.${p[1]}.${p[2]}' == subnetPrefix;
    }

    int userRank(DiscoveredPi d) {
      // Prefer beacon-reported user; UDP/mDNS beat http-scan.
      const sourceRank = {
        'udp-reply': 40,
        'udp': 35,
        'mdns': 30,
        'manual': 25,
        'http-scan': 10,
      };
      var score = sourceRank[d.source] ?? 0;
      if (d.username == 'abpi') score += 2;
      if (d.username == 'delv') score += 1;
      return score;
    }

    return found.values.toList()
      ..sort((a, b) {
        final sa = sameSubnet(a);
        final sb = sameSubnet(b);
        if (sa != sb) return sa ? -1 : 1;
        final ur = userRank(b).compareTo(userRank(a));
        if (ur != 0) return ur;
        return a.ip.compareTo(b.ip);
      });
  }

  bool _ipOnPrefix(String ip, String prefix) {
    final parts = ip.split('.');
    if (parts.length != 4) return false;
    return '${parts[0]}.${parts[1]}.${parts[2]}' == prefix;
  }

  /// Tablet subnet first, then common robot lab subnets.
  Future<List<String>> _scanPrefixes() async {
    final out = <String>[];
    final local = await subnetPrefix();
    if (local != null) out.add(local);
    for (final p in ['192.168.10', '192.168.11', '192.168.1', '192.168.0']) {
      if (!out.contains(p)) out.add(p);
    }
    return out;
  }

  Future<void> _discoverHttpPrefix(
    Map<String, DiscoveredPi> found,
    String prefix,
  ) async {
    final localIp = await _tabletIp();
    const batchSize = 40;
    const hostTimeout = Duration(milliseconds: 600);
    final pending = <Future<void>>[];

    Future<void> flush() async {
      if (pending.isEmpty) return;
      await Future.wait(pending);
      pending.clear();
    }

    for (var host = 1; host <= 254; host++) {
      final ip = '$prefix.$host';
      if (ip == localIp) continue;
      pending.add(() async {
        final info = await probeApiInfo(ip, timeout: hostTimeout);
        if (info == null) return;
        final userRaw = (info['user'] ?? info['pi_user'] ?? defaultPiUsername)
            .toString();
        final user = normalizePiUser(userRaw);
        if (!isAllowedPiUser(user)) return;
        _upsert(
          found,
          DiscoveredPi(
            username: user,
            hostname: (info['host'] ?? info['hostname'] ?? '$user-robot-api')
                .toString(),
            ip: ip,
            apiPort: defaultApiPort,
            source: 'http-scan',
          ),
        );
      }());
      if (pending.length >= batchSize) await flush();
    }
    await flush();
  }

  Future<void> _discoverUdp(
    Map<String, DiscoveredPi> found,
    Duration timeout,
  ) async {
    RawDatagramSocket? socket;
    Timer? probeTimer;
    final done = Completer<void>();
    final probe = utf8.encode(jsonEncode({'discover': _discoverKey}));

    void finish() {
      if (!done.isCompleted) done.complete();
    }

    Timer(timeout, finish);

    try {
      try {
        socket = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4,
          _udpPort,
          reuseAddress: true,
          reusePort: Platform.isAndroid,
        );
      } catch (_) {
        socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      }

      socket.broadcastEnabled = true;

      void onPacket(RawSocketEvent event) {
        if (event != RawSocketEvent.read) return;
        final datagram = socket?.receive();
        if (datagram == null) return;
        try {
          final json =
              jsonDecode(utf8.decode(datagram.data)) as Map<String, dynamic>;
          // Prefer IP inside payload; fall back to packet source address.
          final pi = _piFromJson(
            json,
            source: json['reply'] == true ? 'udp-reply' : 'udp',
            fallbackIp: datagram.address.address,
          );
          if (pi != null) _upsert(found, pi);
        } catch (_) {}
      }

      socket.listen(onPacket);

      void sendProbes() {
        if (socket == null) return;
        final broadcasts = <String>{'255.255.255.255'};
        _tabletIp().then((localIp) {
          if (localIp != null) {
            broadcasts.add(_subnetBroadcast(localIp));
          }
          for (final p in ['192.168.10', '192.168.11', '192.168.1']) {
            broadcasts.add('$p.255');
          }
          for (final b in broadcasts) {
            try {
              socket!.send(probe, InternetAddress(b), _udpPort);
            } catch (_) {}
          }
        });
      }

      sendProbes();
      probeTimer =
          Timer.periodic(const Duration(seconds: 1), (_) => sendProbes());

      await done.future;
    } catch (_) {
      // UDP optional — http scan + manual IP still work.
    } finally {
      probeTimer?.cancel();
      socket?.close();
    }
  }

  Future<void> _discoverMdns(
    Map<String, DiscoveredPi> found,
    Duration timeout,
  ) async {
    final mdns = MDnsClient();
    try {
      await mdns.start();
      await () async {
        await for (final PtrResourceRecord ptr
            in mdns.lookup<PtrResourceRecord>(
          ResourceRecordQuery.serverPointer(_serviceType),
        )) {
          final serviceName = ptr.domainName;
          final low = serviceName.toLowerCase();
          // Accept robot-delv / robot-abpi / robotcontrol services.
          final looksLikeRobot = low.contains('robot') ||
              low.contains('delv') ||
              low.contains('abpi') ||
              low.contains('robotcontrol');
          if (!looksLikeRobot) continue;

          String host = serviceName.split('.').first;
          String ip = '';
          var port = defaultApiPort;
          var username = defaultPiUsername;

          await for (final SrvResourceRecord srv
              in mdns.lookup<SrvResourceRecord>(
            ResourceRecordQuery.service(serviceName),
          )) {
            port = srv.port;
            await for (final IPAddressResourceRecord addr
                in mdns.lookup<IPAddressResourceRecord>(
              ResourceRecordQuery.addressIPv4(srv.target),
            )) {
              ip = addr.address.address;
            }
          }

          await for (final TxtResourceRecord txt
              in mdns.lookup<TxtResourceRecord>(
            ResourceRecordQuery.text(serviceName),
          )) {
            final props = parseTxtProperties(txt.text);
            username = normalizePiUser(props['user'] ?? username);
            host = props['host'] ?? host;
            port = int.tryParse(props['api_port'] ?? '') ?? port;
          }

          // Infer user from service instance name if TXT missing.
          if (!isAllowedPiUser(username) || username == defaultPiUsername) {
            if (low.contains('abpi')) username = 'abpi';
            if (low.contains('delv')) username = 'delv';
          }

          if (ip.isEmpty) continue;
          if (!isAllowedPiUser(username)) continue;
          _upsert(
            found,
            DiscoveredPi(
              username: username,
              hostname: host,
              ip: ip,
              apiPort: port,
              source: 'mdns',
            ),
          );
        }
      }().timeout(timeout);
    } catch (_) {
      // mDNS often fails on Android — UDP + HTTP scan still work.
    } finally {
      mdns.stop();
    }
  }
}
