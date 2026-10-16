import 'package:shared_preferences/shared_preferences.dart';

/// Local app preferences — FR-SET-1 / FR-SET-3 / FR-AUTH-4
class PrefsService {
  static const _keyPiIp = 'pi_ip';
  static const _keyPiPort = 'pi_port';
  static const _keyPiUser = 'pi_ssh_user';
  static const _keyLastUser = 'last_user';
  static const _keyIdleTimeoutMin = 'idle_timeout_minutes';
  static const _keyNotifyBattery = 'notify_battery';
  static const _keyNotifyMission = 'notify_mission';
  static const _keyNotifyLaunch = 'notify_launch';
  static const _keyDarkMode = 'dark_mode';

  static const piUsername = 'delv';

  /// Remove old abpi connection saved on the tablet.
  static Future<void> dropLegacyAbpiConnection() async {
    final p = await SharedPreferences.getInstance();
    final user = p.getString(_keyPiUser)?.toLowerCase();
    if (user == 'abpi' || user == 'pi') {
      await p.remove(_keyPiUser);
    }
    // Old abpi Pi on the lab network — do not reuse.
    if (p.getString(_keyPiIp) == '192.168.10.41') {
      await p.remove(_keyPiIp);
    }
  }

  static Future<void> clearStaleConnection({String? tabletSubnetPrefix}) =>
      dropLegacyAbpiConnection();

  static Future<String> getPiIp() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_keyPiIp) ?? '';
  }

  static Future<String> getPiPort() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_keyPiPort) ?? '8000';
  }

  static Future<int> getIdleTimeoutMinutes() async {
    final p = await SharedPreferences.getInstance();
    return p.getInt(_keyIdleTimeoutMin) ?? 30;
  }

  static Future<bool> getNotifyBattery() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_keyNotifyBattery) ?? true;
  }

  static Future<bool> getNotifyMission() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_keyNotifyMission) ?? true;
  }

  static Future<bool> getNotifyLaunch() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_keyNotifyLaunch) ?? true;
  }

  static Future<void> savePiUsername(String user) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_keyPiUser, user.trim().toLowerCase());
  }

  static Future<String> getPiUsername() async {
    final p = await SharedPreferences.getInstance();
    final saved = p.getString(_keyPiUser);
    if (saved != null && saved.isNotEmpty) {
      return saved;
    }
    return piUsername;
  }

  static Future<void> saveConnection(String ip, String port, {String? username}) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_keyPiIp, ip);
    await p.setString(_keyPiPort, port);
    if (username != null && username.isNotEmpty) {
      await p.setString(_keyPiUser, username.trim().toLowerCase());
    }
  }

  static Future<void> saveLastUser(String user) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_keyLastUser, user);
  }

  static Future<void> setIdleTimeoutMinutes(int minutes) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_keyIdleTimeoutMin, minutes);
  }

  static Future<void> setNotifyBattery(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_keyNotifyBattery, v);
  }

  static Future<void> setNotifyMission(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_keyNotifyMission, v);
  }

  static Future<void> setNotifyLaunch(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_keyNotifyLaunch, v);
  }

  static Future<bool> getDarkMode() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_keyDarkMode) ?? false;
  }

  static Future<void> setDarkMode(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_keyDarkMode, v);
  }
}
