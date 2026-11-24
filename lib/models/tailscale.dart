import 'dart:convert';

import 'package:bett_box/common/common.dart';
import 'package:flutter/foundation.dart';

/// Tailscale 的底层流量（控制面 / DERP / WireGuard）始终直连物理网卡：
/// 这些 socket 会被 VpnService.protect 保护，不进 TUN。
///
/// 为什么不提供「走代理」选项：
/// tsnet 的 magicsock 需要一个**能自由发包的通用 UDP socket**（由它自己
/// 决定往哪发），而 mihomo 的 proxydialer.ListenPacket 只能在已知目标
/// 地址时建立 UDP 关联。把 SystemPacketListener 接到 proxydialer 上会得到
///
///	magicsock: Rebind IPv4 failed: failed to bind any ports (tried [0])
///
/// 节点直接起不来。因此这里只保留直连。

const tailscaleConfigKey = 'tailscale_config';

/// 保存的多凭证列表（含当前启用项）。
const tailscaleProfilesKey = 'tailscale_profiles';

/// tailnet 固定网段，与 core/tailscale_patch.go 里的常量保持一致。
const tailscaleCidr4 = '100.64.0.0/10';
const tailscaleCidr6 = 'fd7a:115c:a1e0::/48';
const defaultTailscaleProxyName = 'Tailscale';

/// Tailscale 配置。
///
/// 不参与 app 的 freezed 模型（避免引入 build_runner 依赖），
/// 单独用 JSON 存在 shared_preferences 里。
/// 一条保存好的登录凭证。
///
/// 为什么是「凭证」而不是「账号」：tsnet 的登录态不可导出（node key 在
/// state-dir 的 tailscaled.state 里），我们能保存的只有两样东西——
/// 用户填的 auth-key，以及这个账号专属的 state-dir 目录名。
/// 前者用于新设备免交互登录，后者让已登录的会话可以整体保留/切换。
///
/// 因此一个凭证 = 一套独立的 state-dir + 可选 auth-key + 一个给人看的标签。
class TailscaleProfile {
  const TailscaleProfile({
    required this.id,
    required this.label,
    this.authKey = '',
    this.loginMethod = TailscaleLoginMethod.unknown,
    this.stateDir = '',
    this.controlUrl = '',
    this.createdAt = 0,
  });

  /// 稳定标识，用来生成 state-dir 目录名。
  final String id;

  /// 用户可见的名字（例如「工作」「个人」）。
  final String label;

  /// 保存的 auth-key，可为空（纯 OAuth 登录的账号就没有）。
  final String authKey;

  /// 这个凭证是用哪种方式登录的。
  final TailscaleLoginMethod loginMethod;

  /// 这个凭证专属的 state-dir 名。空则由 [id] 派生。
  final String stateDir;

  final String controlUrl;

  /// 创建时间（毫秒时间戳），用于排序。
  final int createdAt;

  bool get hasAuthKey => authKey.trim().isNotEmpty;

  /// 实际使用的 state-dir。默认按 id 派生，保证多账号互不干扰。
  String get resolvedStateDir {
    final explicit = stateDir.trim();
    if (explicit.isNotEmpty) return explicit;
    return 'tailscale-$id';
  }

  TailscaleProfile copyWith({
    String? label,
    String? authKey,
    TailscaleLoginMethod? loginMethod,
    String? stateDir,
    String? controlUrl,
  }) {
    return TailscaleProfile(
      id: id,
      label: label ?? this.label,
      authKey: authKey ?? this.authKey,
      loginMethod: loginMethod ?? this.loginMethod,
      stateDir: stateDir ?? this.stateDir,
      controlUrl: controlUrl ?? this.controlUrl,
      createdAt: createdAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'label': label,
    'auth-key': authKey,
    'login-method': loginMethod.name,
    'state-dir': stateDir,
    'control-url': controlUrl,
    'created-at': createdAt,
  };

  factory TailscaleProfile.fromJson(Map<String, dynamic> json) {
    String str(Object? v) => v is String ? v : '';
    int num(Object? v) => v is int ? v : 0;
    return TailscaleProfile(
      id: str(json['id']),
      label: str(json['label']),
      authKey: str(json['auth-key']),
      loginMethod: TailscaleLoginMethod.values.firstWhere(
        (e) => e.name == str(json['login-method']),
        orElse: () => TailscaleLoginMethod.unknown,
      ),
      stateDir: str(json['state-dir']),
      controlUrl: str(json['control-url']),
      createdAt: num(json['created-at']),
    );
  }
}

class TailscaleConfig {
  const TailscaleConfig({
    this.enable = false,
    this.name = defaultTailscaleProxyName,
    this.hostname = '',
    this.authKey = '',
    this.controlUrl = '',
    this.stateDir = 'tailscale',
    this.ephemeral = false,
    this.udp = true,
    this.acceptRoutes = false,
    this.exitNode = '',
    this.exitNodeAllowLanAccess = false,
    this.routeRules = true,
    this.magicDns = true,
    this.dnsSuffix = '',
  });

  final bool enable;

  /// 注入到 proxies 里的节点名，也是 rules / dns 里的 target。
  final String name;
  final String hostname;
  final String authKey;
  final String controlUrl;
  final String stateDir;
  final bool ephemeral;
  final bool udp;
  final bool acceptRoutes;
  final String exitNode;
  final bool exitNodeAllowLanAccess;
  final bool routeRules;
  final bool magicDns;
  final String dnsSuffix;

  /// 是否已经配置好（没有 auth key 时需要手动在 Tailscale 后台点登录链接）。
  bool get hasAuthKey => authKey.trim().isNotEmpty;

  /// 生成的代理节点名（去掉空白，避免 rules 解析出错）。
  String get proxyName {
    final trimmed = name.trim();
    return trimmed.isEmpty ? defaultTailscaleProxyName : trimmed;
  }

  TailscaleConfig copyWith({
    bool? enable,
    String? name,
    String? hostname,
    String? authKey,
    String? controlUrl,
    String? stateDir,
    bool? ephemeral,
    bool? udp,
    bool? acceptRoutes,
    String? exitNode,
    bool? exitNodeAllowLanAccess,
    bool? routeRules,
    bool? magicDns,
    String? dnsSuffix,
  }) {
    return TailscaleConfig(
      enable: enable ?? this.enable,
      name: name ?? this.name,
      hostname: hostname ?? this.hostname,
      authKey: authKey ?? this.authKey,
      controlUrl: controlUrl ?? this.controlUrl,
      stateDir: stateDir ?? this.stateDir,
      ephemeral: ephemeral ?? this.ephemeral,
      udp: udp ?? this.udp,
      acceptRoutes: acceptRoutes ?? this.acceptRoutes,
      exitNode: exitNode ?? this.exitNode,
      exitNodeAllowLanAccess:
          exitNodeAllowLanAccess ?? this.exitNodeAllowLanAccess,
      routeRules: routeRules ?? this.routeRules,
      magicDns: magicDns ?? this.magicDns,
      dnsSuffix: dnsSuffix ?? this.dnsSuffix,
    );
  }

  /// 下发给 core 的 patch 参数（字段名与 core/tailscale_patch.go 对齐）。
  Map<String, dynamic> toPatchJson() {
    return {
      'enable': enable,
      'name': proxyName,
      'hostname': hostname.trim(),
      'auth-key': authKey.trim(),
      'control-url': controlUrl.trim(),
      'state-dir': stateDir.trim(),
      'ephemeral': ephemeral,
      'udp': udp,
      'accept-routes': acceptRoutes,
      'exit-node': exitNode.trim(),
      'exit-node-allow-lan-access': exitNodeAllowLanAccess,
      'route-rules': routeRules,
      'magic-dns': magicDns,
      'dns-suffix': dnsSuffix.trim(),
    };
  }

  Map<String, dynamic> toJson() {
    return {
      'enable': enable,
      'name': name,
      'hostname': hostname,
      'auth-key': authKey,
      'control-url': controlUrl,
      'state-dir': stateDir,
      'ephemeral': ephemeral,
      'udp': udp,
      'accept-routes': acceptRoutes,
      'exit-node': exitNode,
      'exit-node-allow-lan-access': exitNodeAllowLanAccess,
      'route-rules': routeRules,
      'magic-dns': magicDns,
      'dns-suffix': dnsSuffix,
    };
  }

  factory TailscaleConfig.fromJson(Map<String, dynamic> json) {
    bool parseBool(Object? value, bool fallback) {
      if (value is bool) return value;
      if (value is String) return value.toLowerCase() == 'true';
      return fallback;
    }

    String parseString(Object? value, String fallback) {
      return value is String ? value : fallback;
    }

    const defaults = TailscaleConfig();
    return TailscaleConfig(
      enable: parseBool(json['enable'], defaults.enable),
      name: parseString(json['name'], defaults.name),
      hostname: parseString(json['hostname'], defaults.hostname),
      authKey: parseString(json['auth-key'], defaults.authKey),
      controlUrl: parseString(json['control-url'], defaults.controlUrl),
      stateDir: parseString(json['state-dir'], defaults.stateDir),
      ephemeral: parseBool(json['ephemeral'], defaults.ephemeral),
      udp: parseBool(json['udp'], defaults.udp),
      acceptRoutes: parseBool(json['accept-routes'], defaults.acceptRoutes),
      exitNode: parseString(json['exit-node'], defaults.exitNode),
      exitNodeAllowLanAccess: parseBool(
        json['exit-node-allow-lan-access'],
        defaults.exitNodeAllowLanAccess,
      ),
      routeRules: parseBool(json['route-rules'], defaults.routeRules),
      magicDns: parseBool(json['magic-dns'], defaults.magicDns),
      dnsSuffix: parseString(json['dns-suffix'], defaults.dnsSuffix),
    );
  }
}

/// Tailscale 配置的全局单例。
///
/// 用 [ChangeNotifier] 而不是 riverpod provider，是为了避开 build_runner
/// 代码生成（新 provider 需要重新生成 config.g.dart）。
class TailscaleConfigManager extends ChangeNotifier {
  TailscaleConfigManager._();

  static final TailscaleConfigManager instance = TailscaleConfigManager._();

  TailscaleConfig _config = const TailscaleConfig();
  bool _loaded = false;

  TailscaleConfig get config => _config;

  bool get loaded => _loaded;

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    await load();
  }

  Future<void> load() async {
    try {
      final prefs = await preferences.sharedPreferencesCompleter.future;
      final raw = prefs?.getString(tailscaleConfigKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = json.decode(raw);
        if (decoded is Map) {
          _config = TailscaleConfig.fromJson(
            Map<String, dynamic>.from(decoded),
          );
        }
      }
    } catch (e, stackTrace) {
      commonPrint.error('Failed to load tailscale config: $e\n$stackTrace');
    }
    await _loadProfiles();
    _loaded = true;
    notifyListeners();
  }

  /// 这个 state-dir 是否曾经成功登录过。
  ///
  /// 用途：tsnet 对「从没登录」和「登录过期」都只报 NeedsLogin，
  /// 光看 state 分不出来。这里在每次看到 Running 时打个持久化标记，
  /// 下次再遇到 NeedsLogin 就能区分成「过期」而不是「没登录过」。
  ///
  /// 注意：标记按 state-dir 存。换 state-dir 等于换了身份，不能继承。
  Future<bool> hadProfile(String stateDir) async {
    try {
      final prefs = await preferences.sharedPreferencesCompleter.future;
      return prefs?.getBool(_hadProfileKey(stateDir)) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 记录「这个 state-dir 已成功登录过」。
  Future<void> markHadProfile(String stateDir) async {
    try {
      final prefs = await preferences.sharedPreferencesCompleter.future;
      await prefs?.setBool(_hadProfileKey(stateDir), true);
    } catch (_) {
      // 只是提示用途，写失败不影响功能
    }
  }

  /// 清除「曾登录」标记（登出、清空 state-dir 后调用）。
  Future<void> clearHadProfile(String stateDir) async {
    try {
      final prefs = await preferences.sharedPreferencesCompleter.future;
      await prefs?.remove(_hadProfileKey(stateDir));
    } catch (_) {
      // 同上
    }
  }

  String _hadProfileKey(String stateDir) {
    final dir = stateDir.trim().isEmpty ? 'tailscale' : stateDir.trim();
    return 'tailscale_had_profile_$dir';
  }

  /// 读出这个 state-dir 上次登录时用的方式。
  Future<TailscaleLoginMethod> loginMethod(String stateDir) async {
    try {
      final prefs = await preferences.sharedPreferencesCompleter.future;
      final raw = prefs?.getString(_loginMethodKey(stateDir));
      switch (raw) {
        case 'authKey':
          return TailscaleLoginMethod.authKey;
        case 'oauth':
          return TailscaleLoginMethod.oauth;
        default:
          return TailscaleLoginMethod.unknown;
      }
    } catch (_) {
      return TailscaleLoginMethod.unknown;
    }
  }

  /// 记下登录方式。每次观察到 Running 时调用，用当时的配置判断：
  /// 填了 key 就算 authKey，没填就是走浏览器授权。
  Future<void> markLoginMethod(
    String stateDir,
    TailscaleLoginMethod method,
  ) async {
    if (method == TailscaleLoginMethod.unknown) {
      return;
    }
    try {
      final prefs = await preferences.sharedPreferencesCompleter.future;
      await prefs?.setString(
        _loginMethodKey(stateDir),
        method == TailscaleLoginMethod.authKey ? 'authKey' : 'oauth',
      );
    } catch (_) {
      // 只是显示用途，失败不影响功能
    }
  }

  /// 清掉登录方式记录（登出后下次登录可能是另一种方式）。
  Future<void> clearLoginMethod(String stateDir) async {
    try {
      final prefs = await preferences.sharedPreferencesCompleter.future;
      await prefs?.remove(_loginMethodKey(stateDir));
    } catch (_) {
      // 同上
    }
  }

  String _loginMethodKey(String stateDir) {
    final dir = stateDir.trim().isEmpty ? 'tailscale' : stateDir.trim();
    return 'tailscale_login_method_$dir';
  }

  // ---------------------------------------------------------------------
  // 多凭证（多账号）
  //
  // core 侧 PatchParams.Tailscale 是单指针，一次只能注入一个 tailscale
  // 出站，所以这里的设计是「保存多个凭证，同一时刻启用其中一个」。
  // 每个凭证有自己的 state-dir，切换时改 state-dir 即可，互不干扰。
  // ---------------------------------------------------------------------

  List<TailscaleProfile> _profiles = [];
  String _activeProfileId = '';

  List<TailscaleProfile> get profiles => List.unmodifiable(_profiles);

  String get activeProfileId => _activeProfileId;

  TailscaleProfile? get activeProfile {
    for (final p in _profiles) {
      if (p.id == _activeProfileId) return p;
    }
    return _profiles.isEmpty ? null : _profiles.first;
  }

  /// 生成一个不会被重复使用的凭证 id（也用作 state-dir 目录名）。
  String newProfileId() {
    final base = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
    var candidate = base;
    var n = 0;
    while (_profiles.any((p) => p.id == candidate)) {
      n++;
      candidate = '$base-$n';
    }
    return candidate;
  }

  /// 新增一个凭证。同名不合并——标签允许重复，id 保证唯一。
  Future<void> addProfile(TailscaleProfile profile) async {
    _profiles = [..._profiles, profile];
    await _persistProfiles();
  }

  Future<void> updateProfile(TailscaleProfile profile) async {
    _profiles = [
      for (final p in _profiles)
        if (p.id == profile.id) profile else p,
    ];
    await _persistProfiles();
  }

  /// 删除凭证记录。
  ///
  /// 注意：只删「记录」，不动 state-dir 目录。因为删目录需要 core 参与
  /// （要走 Logout + RemoveAll），由调用方决定是否顺便登出。
  Future<void> removeProfile(String id) async {
    _profiles = [
      for (final p in _profiles)
        if (p.id != id) p,
    ];
    if (_activeProfileId == id) {
      _activeProfileId = _profiles.isEmpty ? '' : _profiles.first.id;
    }
    await _persistProfiles();
  }

  Future<void> setActiveProfile(String id) async {
    if (_activeProfileId == id) return;
    if (!_profiles.any((p) => p.id == id)) return;
    _activeProfileId = id;
    await _persistProfiles();
  }

  Future<void> _persistProfiles() async {
    try {
      final prefs = await preferences.sharedPreferencesCompleter.future;
      final raw = json.encode({
        'active': _activeProfileId,
        'items': [for (final p in _profiles) p.toJson()],
      });
      await prefs?.setString(tailscaleProfilesKey, raw);
    } catch (e) {
      commonPrint.error('Failed to persist tailscale profiles: $e');
    }
    notifyListeners();
  }

  Future<void> _loadProfiles() async {
    try {
      final prefs = await preferences.sharedPreferencesCompleter.future;
      final raw = prefs?.getString(tailscaleProfilesKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = json.decode(raw);
      if (decoded is! Map) return;
      final items = decoded['items'];
      if (items is List) {
        _profiles = [
          for (final item in items)
            if (item is Map)
              TailscaleProfile.fromJson(Map<String, dynamic>.from(item)),
        ];
      }
      final active = decoded['active'];
      if (active is String) _activeProfileId = active;
    } catch (e) {
      commonPrint.error('Failed to load tailscale profiles: $e');
    }
  }

  Future<void> save(TailscaleConfig value) async {
    _config = value;
    _loaded = true;
    notifyListeners();
    try {
      final prefs = await preferences.sharedPreferencesCompleter.future;
      if (prefs != null) {
        await prefs.setString(tailscaleConfigKey, json.encode(value.toJson()));
      }
    } catch (e, stackTrace) {
      commonPrint.error('Failed to save tailscale config: $e\n$stackTrace');
    }
  }

  Future<void> update(TailscaleConfig Function(TailscaleConfig state) builder) {
    return save(builder(_config));
  }
}

/// 便捷读取：`tailscaleConfig.enable`。
TailscaleConfig get tailscaleConfig => TailscaleConfigManager.instance.config;

/// 节点状态快照，字段与 core 的 outbound.TailscaleStatus 一一对应。
class TailscaleNodeStatus {
  const TailscaleNodeStatus({
    required this.name,
    required this.state,
    this.hostname = '',
    this.dnsName = '',
    this.ips = const [],
    this.peerCount = 0,
    this.onlinePeers = 0,
    this.authUrl = '',
    this.health = const [],
    this.magicDns = '',
    this.exitNode = '',
    this.dialerProxy = '',
    this.version = '',
    this.error = '',
  });

  final String name;

  /// idle / starting / error / NeedsLogin / NeedsMachineAuth / Running / Stopped
  final String state;
  final String hostname;
  final String dnsName;
  final List<String> ips;
  final int peerCount;
  final int onlinePeers;
  final String authUrl;
  final List<String> health;
  final String magicDns;
  final String exitNode;
  final String dialerProxy;
  final String version;
  final String error;

  bool get isRunning => state == 'Running';

  /// 推断认证方式与认证是否有效。
  ///
  /// [loginMethod] 是 UI 在「登录成功那一刻」记下的方式，不能拿当前的
  /// auth-key 去猜。原因：tsnet 的 profile 里根本不存登录方式
  /// （只有 LoginName / NodeID），而我们自己的配置又可能在登录后被改，
  /// 于是「Running + 当前没有 key」既可能是浏览器 OAuth 登录，也可能是
  /// 「用 key 登录过、之后把 key 从配置里删了但会话仍然有效」。这两种
  /// 情况靠当前配置无法区分，只能靠登录当时记下来的事实。
  ///
  /// [hadProfileBefore] 由 UI 侧记忆「这个 state-dir 之前是否成功登录过」，
  /// 用来区分「从没登录」和「登录过期」——两者 tsnet 都报 NeedsLogin。
  TailscaleAuthStatus authStatus({
    required TailscaleLoginMethod loginMethod,
    required bool hadProfileBefore,
  }) {
    switch (state) {
      case 'Running':
        // 已登录。方式以登录成功时记录下来的为准。
        switch (loginMethod) {
          case TailscaleLoginMethod.authKey:
            return TailscaleAuthStatus.authKey;
          case TailscaleLoginMethod.oauth:
            return TailscaleAuthStatus.oauth;
          case TailscaleLoginMethod.unknown:
            // 登录方式没记下来（例如升级前就已登录），不编造，只报未知。
            return TailscaleAuthStatus.unknown;
        }
      case 'Starting':
      case 'starting':
        return TailscaleAuthStatus.loggingIn;
      case 'NeedsLogin':
      case 'NeedsMachineAuth':
        // 都是「需要授权」，区别在于之前有没有登录过。
        return hadProfileBefore
            ? TailscaleAuthStatus.expired
            : TailscaleAuthStatus.notLoggedIn;
      // NoState 是 tsnet 在「设备已被服务端删除 / node key 失效」时的状态。
      // 实测过：用一次性 key 登录后到后台把设备删掉，重启就落在这里，
      // health 里会带 `invalid key: ... not valid`。这种必然是「登录过期」，
      // 不能落到 default 显示「未知」——那对用户毫无指导意义。
      case 'NoState':
        return hadProfileBefore
            ? TailscaleAuthStatus.expired
            : TailscaleAuthStatus.notLoggedIn;
      case 'Stopped':
        return hadProfileBefore
            ? TailscaleAuthStatus.expired
            : TailscaleAuthStatus.notLoggedIn;
      default:
        return TailscaleAuthStatus.unknown;
    }
  }

  bool get needsLogin => state == 'NeedsLogin' || state == 'NeedsMachineAuth';

  /// 解析 `{"nodes": [...]}` 结构，取名字匹配的第一个节点。
  ///
  /// 注意：core 返回的可能不是 JSON —— 例如 action 里 recover 到的
  /// `panic: ...`、或者 `{"code":-1}` 的纯文本错误。这种情况下要把
  /// **原文**当作错误显示出来，不能只报一个 FormatException。
  static TailscaleNodeStatus? parse(String name, String raw) {
    if (raw.isEmpty) return null;
    final trimmed = raw.trimLeft();
    if (!trimmed.startsWith('{')) {
      return TailscaleNodeStatus(
        name: name,
        state: 'error',
        error: raw.length > 400 ? '${raw.substring(0, 400)}…' : raw,
      );
    }
    try {
      final decoded = json.decode(trimmed);
      if (decoded is! Map) return null;
      final nodes = decoded['nodes'];
      if (nodes is! List || nodes.isEmpty) return null;
      Map<dynamic, dynamic>? matched;
      for (final node in nodes) {
        if (node is Map && node['name'] == name) {
          matched = node;
          break;
        }
      }
      matched ??= nodes.first is Map ? nodes.first as Map : null;
      if (matched == null) return null;
      return TailscaleNodeStatus.fromJson(
        Map<String, dynamic>.from(matched),
      );
    } catch (e) {
      return TailscaleNodeStatus(
        name: name,
        state: 'error',
        error: 'parse failed: $e',
      );
    }
  }

  factory TailscaleNodeStatus.fromJson(Map<String, dynamic> json) {
    List<String> parseList(Object? value) {
      if (value is List) return value.map((item) => '$item').toList();
      return const [];
    }

    int parseInt(Object? value) {
      if (value is int) return value;
      if (value is num) return value.toInt();
      if (value is String) return int.tryParse(value) ?? 0;
      return 0;
    }

    String parseString(Object? value) => value is String ? value : '';

    return TailscaleNodeStatus(
      name: parseString(json['name']),
      state: parseString(json['state']),
      hostname: parseString(json['hostname']),
      dnsName: parseString(json['dns-name']),
      ips: parseList(json['ips']),
      peerCount: parseInt(json['peer-count']),
      onlinePeers: parseInt(json['online-peers']),
      authUrl: parseString(json['auth-url']),
      health: parseList(json['health']),
      magicDns: parseString(json['magic-dns']),
      exitNode: parseString(json['exit-node']),
      dialerProxy: parseString(json['dialer-proxy']),
      version: parseString(json['version']),
      error: parseString(json['error']),
    );
  }
}

/// 登录时实际使用的凭据方式。
///
/// 为什么要单独记录：tsnet 的 profile 里不保存登录方式（只有 LoginName /
/// NodeID），而我们的配置又可能在登录后被用户改动。于是「已登录 + 当前没有
/// auth-key」存在两种可能——浏览器 OAuth 登录，或「用 key 登录过、之后把 key
/// 从配置里删了但会话仍然有效」。这两种只能靠登录当时记下来的事实区分。
enum TailscaleLoginMethod {
  /// 不知道（升级前就已登录，或记录丢失）。
  unknown,

  /// 用 auth-key 免交互登录。
  authKey,

  /// 用浏览器打开登录链接授权。
  oauth,
}

/// Tailscale 的认证方式 / 认证状态。
///
/// 为什么需要单独判断：tsnet 的 `state` 只告诉你是 Running 还是 NeedsLogin，
/// 但「Running」可能是用 auth-key 登的，也可能是用浏览器 OAuth 登的；
/// 而「NeedsLogin」既可能是从没登录过，也可能是登录过期了。
/// 这三种情况的用户下一步动作完全不同，所以要在 UI 上区分开。
enum TailscaleAuthStatus {
  /// 节点未启动（或内核没在跑），还不知道认证情况。
  unknown,

  /// 用 auth-key 免交互登录成功。
  authKey,

  /// 用浏览器 OAuth 登录成功。
  oauth,

  /// 从未登录，等待授权。
  notLoggedIn,

  /// 曾经登录过，但凭证失效/被登出，需要重新授权。
  expired,

  /// 正在登录过程中。
  loggingIn,
}

extension TailscaleAuthStatusInfo on TailscaleAuthStatus {
  /// 是否已经处于可用状态。
  bool get isAuthenticated =>
      this == TailscaleAuthStatus.authKey || this == TailscaleAuthStatus.oauth;

  /// 是否需要用户去做授权动作（点登录链接 / 填 key）。
  bool get needsUserAction =>
      this == TailscaleAuthStatus.notLoggedIn ||
      this == TailscaleAuthStatus.expired;
}
