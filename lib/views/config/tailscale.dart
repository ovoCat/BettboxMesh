import 'dart:async';

import 'package:bett_box/clash/clash.dart';
import 'package:bett_box/common/common.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/app.dart' show runTimeProvider;
import 'package:bett_box/state.dart';
import 'package:bett_box/widgets/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

/// Tailscale 页面。
///
/// 设计要点：
/// 1. 只有一份 VpnService：Tailscale 以 userspace netstack（tsnet）的形式
///    跑在 core 进程内，和 TUN 共存，不需要第二个 VPN 授权；
/// 2. 发往 tailnet（100.64.0.0/10、fd7a:115c:a1e0::/48、*.ts.net）的流量
///    由 core 注入的规则送进 tailscale 出站；
/// 3. 底层流量（控制面/DERP/WireGuard）**只支持直连**，原因见
///    lib/models/tailscale.dart 顶部注释。
///
/// 同一个 Widget 两处复用：底部导航栏的独立页（asPage: true），以及
/// 「内核配置」里的二级入口（asPage: false）。
class TailscaleListView extends ConsumerStatefulWidget {
  /// [asPage] 为 true 时作为独立导航页使用（自带标题栏与刷新/连接按钮），
  /// 为 false 时嵌在「内核配置」里，沿用外层 AppBar。
  const TailscaleListView({super.key, this.asPage = false});

  final bool asPage;

  @override
  ConsumerState<TailscaleListView> createState() => _TailscaleListViewState();
}

class _TailscaleListViewState extends ConsumerState<TailscaleListView>
    with WidgetsBindingObserver {
  Timer? _statusTimer;
  TailscaleNodeStatus? _status;
  bool _statusLoading = false;

  /// 手动刷新时按钮转圈用；和 [_statusLoading]（防止并发查询）区分开。
  bool _refreshing = false;

  /// 这个 state-dir 是否曾经登录成功过（用于区分「从没登录」和「登录过期」）。
  bool _hadProfile = false;

  /// 上次登录成功时用的方式，由登录那一刻的配置记录。
  TailscaleLoginMethod _loginMethod = TailscaleLoginMethod.unknown;

  /// 当前这次状态查询的完成信号，手动刷新撞上轮询时用它等一等。
  Completer<void>? _pollingDone;

  /// 进入后台的时刻，用于浏览器授权返回后立即刷新状态（过滤输入法等短暂切换）。
  DateTime? _pausedAt;

  TailscaleConfig get _config => TailscaleConfigManager.instance.config;

  /// 给「不依赖 build 上下文」的地方（如手动刷新的提示）取文案用。
  String Function(String key) get _t {
    final lang = Localizations.localeOf(context).languageCode;
    return (key) => _strings[key]?[lang] ?? _strings[key]?['en'] ?? key;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 必须先加载：manager 是单例但不会自动读盘。
    // 不加载的话 _config 是默认值(enable=false)、_profiles 为空，
    // 表现就是「已保存的凭证全都不见了」+「开关状态回退」。
    // 实机上尤其明显：debug 期间刚添加过、内存里有数据看着正常，
    // 一旦重启或换成正式版就暴露。
    unawaited(_ensureLoaded());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _pausedAt = DateTime.now();
      return;
    }
    if (state != AppLifecycleState.resumed) return;
    final pausedAt = _pausedAt;
    _pausedAt = null;
    if (pausedAt == null) return;
    if (DateTime.now().difference(pausedAt) < const Duration(seconds: 2)) {
      return;
    }
    if (_config.enable &&
        TailscaleConfigManager.instance.activeProfile != null) {
      unawaited(_refreshStatus(force: true));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _statusTimer?.cancel();
    super.dispose();
  }

  /// 从磁盘加载配置与凭证列表，加载完再启动状态轮询。
  ///
  /// 顺序很重要：必须先 load 再用 _config 判断 enable，
  /// 否则会用默认值(disable)起轮询，页面永远不刷新状态。
  Future<void> _ensureLoaded() async {
    await TailscaleConfigManager.instance.ensureLoaded();
    if (!mounted) return;
    setState(() {});
    _startPolling();
  }

  void _startPolling() {
    _statusTimer?.cancel();
    if (!_config.enable ||
        TailscaleConfigManager.instance.activeProfile == null) {
      return;
    }
    _statusTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _refreshStatus(),
    );
    unawaited(_refreshStatus());
  }

  /// 手动刷新：和定时轮询共用查询逻辑，但一定要给用户可见的反馈。
  ///
  /// 之前直接复用 [_refreshStatus]，而它有三个「静默」特性，导致点了像没反应：
  ///  1. 定时轮询每 5 秒就跑一次，手动刷新往往查到的是一模一样的状态；
  ///  2. 全程没有 loading 指示；
  ///  3. 如果撞上轮询正在跑（_statusLoading == true）会直接 return，
  ///     连请求都不发。
  /// 这里改成：强制发起一次查询、按钮转圈、结束后弹一条结果提示。
  Future<void> _manualRefresh() async {
    if (_statusLoading) {
      // 撞上轮询：等它结束再补一次，保证这次点击一定有结果。
      await _pollingDone?.future.timeout(
        const Duration(seconds: 15),
        onTimeout: () {},
      );
    }
    setState(() => _refreshing = true);
    try {
      await _refreshStatus(force: true);
    } finally {
      if (mounted) {
        setState(() => _refreshing = false);
      }
    }
    if (!mounted) return;
    final state = _status?.state ?? '';
    final ip = (_status?.ips.isNotEmpty ?? false) ? _status!.ips.first : '-';
    globalState.showNotifier('${_stateText(state, _t)} · $ip');
  }

  Future<void> _refreshStatus({bool force = false}) async {
    if (_statusLoading) {
      if (!force) return;
      // force 时等当前这次结束，避免并发打同一个 action。
      await _pollingDone?.future.timeout(
        const Duration(seconds: 15),
        onTimeout: () {},
      );
      if (_statusLoading) return;
    }
    _statusLoading = true;
    _pollingDone = Completer<void>();
    try {
      final raw = await clashCore.getTailscaleStatus(name: _config.proxyName);
      final status = TailscaleNodeStatus.parse(_config.proxyName, raw);
      if (!mounted) return;
      // 一旦见过 Running，就记住这个 state-dir 曾经登录成功过，
      // 并记下登录方式（用配置里当时有没有 key 来判断）。
      // 之后遇到 NeedsLogin 才能区分成「过期」而不是「没登录过」。
      if (status != null && status.isRunning) {
        unawaited(
          TailscaleConfigManager.instance.markHadProfile(_config.stateDir),
        );
        // 只在还没记录过时写入：一旦记录，就以第一次登录成功的事实为准。
        // 否则用户登录后把 key 删掉，这里会被覆盖成 oauth，判断就错了。
        if (_loginMethod == TailscaleLoginMethod.unknown) {
          unawaited(
            TailscaleConfigManager.instance.markLoginMethod(
              _config.stateDir,
              _config.hasAuthKey
                  ? TailscaleLoginMethod.authKey
                  : TailscaleLoginMethod.oauth,
            ),
          );
        }
      }
      if (mounted) {
        final had = await TailscaleConfigManager.instance.hadProfile(
          _config.stateDir,
        );
        final method = await TailscaleConfigManager.instance.loginMethod(
          _config.stateDir,
        );
        if (!mounted) return;
        setState(() {
          _status = status;
          _hadProfile = had;
          _loginMethod = method;
        });
      }
    } catch (e) {
      // 进日志页，方便连日志一起导出定位。
      commonPrint.warn('Tailscale status query failed: $e');
      if (!mounted) return;
      setState(() {
        _status = TailscaleNodeStatus(
          name: _config.proxyName,
          state: 'error',
          error: '$e',
        );
      });
    } finally {
      _statusLoading = false;
      _pollingDone?.complete();
      _pollingDone = null;
    }
  }

  Future<void> _connect() async {
    if (TailscaleConfigManager.instance.activeProfile == null) {
      globalState.showNotifier(_tr('credentialNoneDesc'));
      return;
    }
    try {
      final error = await clashCore.startTailscale(name: _config.proxyName);
      if (!mounted) return;
      if (error.isNotEmpty) {
        globalState.showNotifier(error);
        return;
      }
      await _refreshStatus();
      // 点「连接」通常就是为了拿登录链接：tsnet 起来后要先做 control 握手
      // 和 netmap 同步，BackendState 才会从 Starting 变 NeedsLogin 并带上
      // auth-url。默认 5 秒一轮的话用户会干等十几秒看不到链接，
      // 这里临时加速几轮，拿到链接或状态稳定后再回到常规节奏。
      unawaited(_pollUntilAuthUrl());
    } catch (e) {
      if (!mounted) return;
      globalState.showNotifier('$e');
    }
  }

  /// 连接后短暂加速轮询，尽快把 auth-url 呈现出来。
  Future<void> _pollUntilAuthUrl() async {
    for (var i = 0; i < 10; i++) {
      await Future.delayed(const Duration(milliseconds: 800));
      if (!mounted || !_config.enable) {
        return;
      }
      await _refreshStatus();
      final status = _status;
      if (status == null) {
        continue;
      }
      // 已经拿到登录链接，或者已经登录成功、进入终态，就不必再加速了。
      if (status.authUrl.isNotEmpty ||
          status.state == 'Running' ||
          status.state == 'NeedsMachineAuth' ||
          status.state == 'error' ||
          status.state == 'absent') {
        return;
      }
    }
  }

  Future<void> _save(
    TailscaleConfig value, {

    /// 切换凭证时传 true：这是换身份，不是改 key，
    /// 不该触发「key 变了就登出」那段逻辑（那段会连 control plane，
    /// 在切换场景下容易超时并拖垮后面的 restartCore）。
    bool skipAutoLogout = false,
  }) async {
    final previous = _config;
    // 判断这次改动是否影响内核配置。
    //
    // 为什么要区分：Bettbox 有两条路径
    //   updateConfig（轻量）—— 只改端口/模式/日志级别等运行时参数，
    //                          完全不碰 proxies / rules / dns；
    //   setupConfig（全量）—— 重新解析 rawConfig、重建 tunnel，
    //                        Tailscale 的出站/规则/DNS 只有这条路能生效。
    // 之前统一调 updateClashConfig()（走 updateConfig），所以：
    //   * 首次开启 → 出站没注入，必须重启 App 才生效；
    //   * 关闭开关 → 旧出站没移除，Tailscale 继续工作，开关形同摆设。
    final needsRebuild = _needsCoreRebuild(previous, value);
    await TailscaleConfigManager.instance.save(value);
    if (!mounted) return;
    setState(() {});
    if (!value.enable) {
      _statusTimer?.cancel();
    } else {
      _startPolling();
    }

    // auth-key 被清空或改成别的值时，要让节点真的退出登录。
    //
    // 背景：登录态（node key）落在 state-dir 里，只要那个目录还在，tsnet
    // 重启后会直接恢复登录。所以「删掉 auth-key」并不会退出登录，用户会
    // 看到「key 明明删了，状态还是运行中」，也就永远走不到需要授权的
    // NeedsLogin 分支、拿不到新的登录链接——这正是当初被报上来的现象。
    //
    // 换 key 也要先登出：旧节点身份必须解绑，否则新 key 授权的是另一台
    // 逻辑设备，tailnet 里会留下僵尸条目。
    final authKeyChanged =
        !skipAutoLogout && previous.authKey.trim() != value.authKey.trim();
    if (authKeyChanged && value.enable) {
      try {
        final error = await clashCore.logoutTailscale(
          name: value.proxyName,
          stateDir: value.stateDir,
        );
        if (error.isNotEmpty) {
          commonPrint.warn('Tailscale logout returned: $error');
        }
        // 登出会把 state-dir 清掉，之前那个「曾登录」标记就不再适用了，
        // 否则重新登录前状态会误显示成「登录已过期」而不是「未登录」。
        await TailscaleConfigManager.instance.clearHadProfile(value.stateDir);
        await TailscaleConfigManager.instance.clearLoginMethod(value.stateDir);
        _hadProfile = false;
        _loginMethod = TailscaleLoginMethod.unknown;
        await _refreshStatus();
      } catch (e) {
        commonPrint.warn('Tailscale logout failed: $e');
      }
    }

    if (!needsRebuild) {
      return;
    }
    // 先打标记：即使内核对当前没在跑，也要让「下一次启动」知道配置变过，
    // 从而跳过快路径强制走 setupConfig（否则出站不会注入）。
    globalState.appController.markTailscaleConfigChanged();
    // VPN 没在跑时内核是空闲的，等用户点「启动开关」时自然会走
    // setupConfig，这里不需要（也不应该）白白重启一次。
    final isCoreRunning = ref.read(runTimeProvider) != null;
    if (!isCoreRunning) {
      return;
    }
    try {
      // 全量重建：handleStop → setupConfig → handleStart，会短暂断流但配置一定生效。
      await globalState.appController.restartCore();
    } catch (e) {
      commonPrint.warn('Tailscale config apply failed: $e');
      if (mounted) {
        globalState.showNotifier('$e');
      }
    }
  }

  /// 判断配置变化是否需要重建内核（即走 setupConfig）。
  ///
  /// 只有真正影响注入结果的字段才算：开关、节点名、Auth Key、控制面地址、
  /// 主机名、路由规则、MagicDNS、DNS 后缀、exit node、子网路由。
  /// 其余（如状态轮询）不需要动内核。
  bool _needsCoreRebuild(TailscaleConfig a, TailscaleConfig b) {
    return a.enable != b.enable ||
        a.proxyName != b.proxyName ||
        a.hostname.trim() != b.hostname.trim() ||
        a.authKey.trim() != b.authKey.trim() ||
        a.controlUrl.trim() != b.controlUrl.trim() ||
        a.stateDir.trim() != b.stateDir.trim() ||
        a.ephemeral != b.ephemeral ||
        a.udp != b.udp ||
        a.acceptRoutes != b.acceptRoutes ||
        a.exitNode.trim() != b.exitNode.trim() ||
        a.exitNodeAllowLanAccess != b.exitNodeAllowLanAccess ||
        a.routeRules != b.routeRules ||
        a.magicDns != b.magicDns ||
        a.dnsSuffix.trim() != b.dnsSuffix.trim();
  }

  /// 统一的文本输入项：对话框取消（null）时不改动配置，
  /// 避免把已经填好的 key / 名字清空。
  // ---------------------------------------------------------------------
  // 多凭证
  //
  // core 侧一次只能注入一个 tailscale 出站，所以这里不做「同时登录多个」，
  // 而是「保存多个凭证、切换启用其中一个」。每个凭证有独立 state-dir，
  // 切换就是换 state-dir，会话互不影响。
  // ---------------------------------------------------------------------

  /// 「添加登录凭证」页面：先让用户选方式，再走对应的录入流程。
  Widget _buildCredentialPage(String Function(String key) t) {
    return _CredentialListView(master: this, t: t);
  }

  /// 添加凭证：Auth Key 方式。
  Future<void> _addByAuthKey(String Function(String key) t) async {
    final label = await globalState.showCommonDialog<String>(
      child: InputDialog(
        value: '',
        title: t('credentialLabel'),
        hintText: t('credentialLabelHint'),
      ),
    );
    if (!mounted || label == null || label.trim().isEmpty) return;
    final key = await globalState.showCommonDialog<String>(
      child: InputDialog(
        value: '',
        title: t('authKey'),
        hintText: 'tskey-auth-...',
      ),
    );
    if (!mounted || key == null || key.trim().isEmpty) return;
    final id = TailscaleConfigManager.instance.newProfileId();
    await TailscaleConfigManager.instance.addProfile(
      TailscaleProfile(
        id: id,
        label: label.trim(),
        authKey: key.trim(),
        loginMethod: TailscaleLoginMethod.authKey,
        stateDir: 'tailscale-$id',
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    if (TailscaleConfigManager.instance.profiles.length == 1) {
      await TailscaleConfigManager.instance.setActiveProfile(id);
    }
    if (!mounted) return;
    setState(() {});
    // auth-key 是用户主动提供的凭证，添加时就该算「已配置」。
    // 不能等状态变成 Running 才标记——VPN 没开时永远看不到 Running，
    // 那样管理页会一直显示「需要浏览器授权」，误导用户。
    await TailscaleConfigManager.instance.markHadProfile('tailscale-$id');
    await TailscaleConfigManager.instance.markLoginMethod(
      'tailscale-$id',
      TailscaleLoginMethod.authKey,
    );
    final profile = TailscaleConfigManager.instance.activeProfile;
    if (profile != null && profile.id == id) {
      await _activateProfile(profile);
    }
    if (!mounted) return;
    globalState.showNotifier(t('credentialAdded'));
  }

  /// 添加凭证：浏览器授权方式。
  Future<void> _addByOAuth(String Function(String key) t) async {
    final label = await globalState.showCommonDialog<String>(
      child: InputDialog(
        value: '',
        title: t('credentialLabel'),
        hintText: t('credentialLabelHint'),
      ),
    );
    if (!mounted || label == null || label.trim().isEmpty) return;
    final id = TailscaleConfigManager.instance.newProfileId();
    await TailscaleConfigManager.instance.addProfile(
      TailscaleProfile(
        id: id,
        label: label.trim(),
        authKey: '',
        loginMethod: TailscaleLoginMethod.oauth,
        stateDir: 'tailscale-$id',
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    if (TailscaleConfigManager.instance.profiles.length == 1) {
      await TailscaleConfigManager.instance.setActiveProfile(id);
    }
    if (!mounted) return;
    setState(() {});
    final profile = TailscaleConfigManager.instance.activeProfile;
    if (profile != null && profile.id == id) {
      // VPN 没在跑时不需要激活（重建会被跳过），提示用户去开启即可。
      if (isCoreRunning) {
        await _activateProfile(profile);
      } else {
        globalState.showNotifier(t('oauthNeedVpn'));
      }
    }
  }

  /// 供管理页读取当前状态（它是另一个 State，拿不到私有字段）。
  TailscaleNodeStatus? get currentStatus => _status;

  /// 内核（VPN）是否在运行。
  ///
  /// 管理页是纯 State，拿不到 ref，所以由这里代查。
  /// Tailscale 出站依附于内核，VPN 没开时无法获取登录链接。
  bool get isCoreRunning => ref.read(runTimeProvider) != null;

  /// 切换凭证后把状态清空。
  ///
  /// restartCore 之后内核是新实例，_status 还是旧凭证的快照。
  /// 如果旧凭证登录着（Running），管理页会误判「新凭证也已登录」，
  /// 从而跳过浏览器授权。清空后强制等一次真实查询。
  void resetStatusForSwitch() {
    if (!mounted) return;
    setState(() {
      _status = null;
    });
  }

  /// 启用某个凭证：把 auth-key / state-dir 写进当前配置并重建内核。
  Future<void> _activateProfile(
    TailscaleProfile profile, {
    bool confirm = false,
  }) async {
    // 切换会走 restartCore（全量 setupConfig），VPN 要短暂断开。
    // 用户点列表项就断网是意外行为，所以先说明再执行。
    if (confirm &&
        profile.id != TailscaleConfigManager.instance.activeProfileId) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(_tr('credentialSwitch')),
          content: Text('${profile.label}\n\n${_tr('credentialSwitchDesc')}'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(_tr('cancel')),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(_tr('confirm')),
            ),
          ],
        ),
      );
      if (!mounted || ok != true) return;
    }

    final next = _config.copyWith(
      authKey: profile.authKey,
      stateDir: profile.resolvedStateDir,
      controlUrl: profile.controlUrl,
    );
    await TailscaleConfigManager.instance.setActiveProfile(profile.id);
    await _save(next, skipAutoLogout: true);
  }

  /// 删除凭证（顺带登出，避免 state-dir 残留占用）。
  Future<void> _removeProfile(
    TailscaleProfile profile,
    String Function(String key) t,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t('credentialRemove')),
        content: Text(profile.label),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(t('cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(t('confirm')),
          ),
        ],
      ),
    );
    if (!mounted || ok != true) return;
    try {
      await clashCore.logoutTailscale(
        name: profile.label,
        stateDir: profile.resolvedStateDir,
      );
    } catch (e) {
      commonPrint.warn('logout before remove failed: $e');
    }
    await TailscaleConfigManager.instance.removeProfile(profile.id);
    await TailscaleConfigManager.instance.clearHadProfile(
      profile.resolvedStateDir,
    );
    await TailscaleConfigManager.instance.clearLoginMethod(
      profile.resolvedStateDir,
    );
    if (!mounted) return;
    setState(() {});
    final active = TailscaleConfigManager.instance.activeProfile;
    if (active != null) {
      await _activateProfile(active);
    } else {
      _status = null;
      _hadProfile = false;
      _loginMethod = TailscaleLoginMethod.unknown;
      await _save(
        _config.copyWith(authKey: '', stateDir: 'tailscale', controlUrl: ''),
        skipAutoLogout: true,
      );
    }
  }

  /// 给不接收 t 参数的成员方法用的文案辅助。
  ///
  /// build() 里的 t 是局部闭包，_activateProfile 这类方法拿不到，
  /// 这里按同样规则从 context 取一次。
  String _tr(String key) {
    final lang = Localizations.localeOf(context).languageCode;
    return _strings[key]?[lang] ?? _strings[key]?['en'] ?? key;
  }

  InputDelegate _input({
    required String title,
    required String value,
    String? hint,
    required TailscaleConfig Function(String value) update,
  }) {
    return InputDelegate(
      title: title,
      value: value,
      hintText: hint,
      onChanged: (raw) {
        if (raw == null) return;
        _save(update(raw));
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final lang = Localizations.localeOf(context).languageCode;
    String t(String key) => _strings[key]?[lang] ?? _strings[key]?['en'] ?? key;

    // 作为独立导航页时（asPage）需要自带标题栏；嵌在内核配置里时沿用外层。
    // 刷新/连接按钮只放在「状态」区块里（离状态卡片近，语义清楚），
    // AppBar 上不再重复放一份。
    if (widget.asPage) {
      return CommonScaffold(
        title: 'Tailscale',
        body: generateListView(_buildItems(t)),
      );
    }
    return generateListView(_buildItems(t));
  }

  List<Widget> _buildItems(String Function(String key) t) {
    final config = _config;
    final items = <Widget>[
      ...generateSection(
        items: [
          ListItem.switchItem(
            leading: const Icon(Icons.hub_outlined),
            title: Text(t('enable')),
            subtitle: Text(t('enableDesc')),
            delegate: SwitchDelegate(
              value: config.enable,
              onChanged: (value) => _save(config.copyWith(enable: value)),
            ),
          ),
        ],
      ),
      ...generateSection(
        title: t('credentials'),
        items: [
          // 当前启用的凭证（没有则显示提示）。
          ListItem(
            leading: const Icon(Icons.badge_outlined),
            title: Text(t('credentialCurrent')),
            subtitle: Text(
              TailscaleConfigManager.instance.activeProfile?.label ??
                  t('credentialNone'),
            ),
          ),
          ListItem.next(
            leading: const Icon(Icons.add_moderator_outlined),
            title: Text(t('addCredential')),
            subtitle: Text(t('addCredentialDesc')),
            delegate: NextDelegate(
              title: t('addCredential'),
              builder: (_) => _buildCredentialPage(t),
            ),
          ),
        ],
      ),

      if (config.enable) ...[
        ...generateSection(
          title: t('status'),
          actions: [
            IconButton(
              tooltip: t('refresh'),
              onPressed: _refreshing ? null : _manualRefresh,
              icon: _refreshing
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
            ),
            IconButton(
              tooltip: t('connect'),
              onPressed: _connect,
              icon: const Icon(Icons.link),
            ),
          ],
          items: _buildStatusItems(t),
        ),
        ...generateSection(
          title: t('node'),
          items: [
            ListItem.input(
              leading: const Icon(Icons.badge_outlined),
              title: Text(t('nodeName')),
              subtitle: Text(t('nodeNameDesc')),
              delegate: _input(
                title: t('nodeName'),
                value: config.name,
                hint: defaultTailscaleProxyName,
                update: (value) => config.copyWith(name: value),
              ),
            ),
            ListItem.input(
              leading: const Icon(Icons.computer_outlined),
              title: Text(t('hostname')),
              subtitle: Text(t('hostnameDesc')),
              delegate: _input(
                title: t('hostname'),
                value: config.hostname,
                hint: t('hostnameHint'),
                update: (value) => config.copyWith(hostname: value),
              ),
            ),
            ListItem.input(
              leading: const Icon(Icons.dns_outlined),
              title: Text(t('controlUrl')),
              subtitle: Text(t('controlUrlDesc')),
              delegate: _input(
                title: t('controlUrl'),
                value: config.controlUrl,
                hint: 'https://controlplane.tailscale.com',
                update: (value) => config.copyWith(controlUrl: value),
              ),
            ),
            ListItem.input(
              leading: const Icon(Icons.logout_outlined),
              title: Text(t('exitNode')),
              subtitle: Text(t('exitNodeDesc')),
              delegate: _input(
                title: t('exitNode'),
                value: config.exitNode,
                hint: t('exitNodeHint'),
                update: (value) => config.copyWith(exitNode: value),
              ),
            ),
          ],
        ),
        ...generateSection(
          title: t('routing'),
          items: [
            ListItem.switchItem(
              leading: const Icon(Icons.route_outlined),
              title: Text(t('routeRules')),
              subtitle: Text(t('routeRulesDesc')),
              delegate: SwitchDelegate(
                value: config.routeRules,
                onChanged: (value) => _save(config.copyWith(routeRules: value)),
              ),
            ),
            ListItem.switchItem(
              leading: const Icon(Icons.dns_outlined),
              title: Text(t('magicDns')),
              subtitle: Text(t('magicDnsDesc')),
              delegate: SwitchDelegate(
                value: config.magicDns,
                onChanged: (value) => _save(config.copyWith(magicDns: value)),
              ),
            ),
            ListItem.input(
              leading: const Icon(Icons.text_fields_outlined),
              title: Text(t('dnsSuffix')),
              subtitle: Text(t('dnsSuffixDesc')),
              delegate: _input(
                title: t('dnsSuffix'),
                value: config.dnsSuffix,
                hint: 'ts.net',
                update: (value) => config.copyWith(dnsSuffix: value),
              ),
            ),
            ListItem.switchItem(
              leading: const Icon(Icons.lan_outlined),
              title: Text(t('acceptRoutes')),
              subtitle: Text(t('acceptRoutesDesc')),
              delegate: SwitchDelegate(
                value: config.acceptRoutes,
                onChanged: (value) =>
                    _save(config.copyWith(acceptRoutes: value)),
              ),
            ),
            ListItem.switchItem(
              leading: const Icon(Icons.lan_outlined),
              title: Text(t('exitNodeAllowLan')),
              subtitle: Text(t('exitNodeAllowLanDesc')),
              delegate: SwitchDelegate(
                value: config.exitNodeAllowLanAccess,
                onChanged: (value) =>
                    _save(config.copyWith(exitNodeAllowLanAccess: value)),
              ),
            ),
            ListItem.switchItem(
              leading: const Icon(Icons.bolt_outlined),
              title: Text(t('udp')),
              subtitle: Text(t('udpDesc')),
              delegate: SwitchDelegate(
                value: config.udp,
                onChanged: (value) => _save(config.copyWith(udp: value)),
              ),
            ),
            ListItem.switchItem(
              leading: const Icon(Icons.timer_outlined),
              title: Text(t('ephemeral')),
              subtitle: Text(t('ephemeralDesc')),
              delegate: SwitchDelegate(
                value: config.ephemeral,
                onChanged: (value) => _save(config.copyWith(ephemeral: value)),
              ),
            ),
          ],
        ),
        ...generateSection(
          title: t('notes'),
          items: [
            ListItem(
              title: Text(t('noteOneVpn')),
              subtitle: Text(t('noteOneVpnDesc')),
            ),
            ListItem(
              title: Text(t('noteMagicDns')),
              subtitle: Text(t('noteMagicDnsDesc')),
            ),
            ListItem(
              title: Text(t('transportMode')),
              subtitle: Text(t('transportModeDesc')),
            ),
          ],
        ),
      ],
    ];

    return items;
  }

  List<Widget> _buildStatusItems(String Function(String key) t) {
    if (TailscaleConfigManager.instance.activeProfile == null) {
      return [
        ListItem(
          leading: const Icon(Icons.info_outline),
          title: Text(t('credentialNone')),
          subtitle: Text(t('credentialNoneDesc')),
        ),
      ];
    }
    final status = _status;
    if (status == null) {
      return [
        ListItem(
          leading: const Icon(Icons.hourglass_empty),
          title: Text(t('statusUnknown')),
          subtitle: Text(
            _config.hasAuthKey ? t('statusIdleHint') : t('statusAuthHint'),
          ),
        ),
      ];
    }
    final ips = status.ips.isEmpty ? '-' : status.ips.join(', ');
    final auth = status.authStatus(
      loginMethod: _loginMethod,
      hadProfileBefore: _hadProfile,
    );
    final detail = StringBuffer()
      ..write('${t('state')}: ${_stateText(status.state, t)}')
      ..write('\n${t('authStatus')}: ${_authStatusText(auth, t)}')
      ..write('\n${t('tailnetIp')}: $ips');
    if (status.magicDns.isNotEmpty) {
      detail.write('\nMagicDNS: ${status.magicDns}');
    }
    if (status.peerCount > 0) {
      detail.write(
        '\n${t('peers')}: ${status.onlinePeers}/${status.peerCount}',
      );
    }
    if (status.health.isNotEmpty) {
      detail.write('\n${t('health')}: ${status.health.join('; ')}');
    }
    if (status.error.isNotEmpty) {
      detail.write('\n${t('error')}: ${status.error}');
    }
    final statusItem = ListItem(
      leading: const Icon(Icons.insights_outlined),
      title: Text(status.hostname.isEmpty ? status.name : status.hostname),
      subtitle: Text(detail.toString()),
    );
    // 需要交互式登录时，auth-url 只有在这里出现。
    // 之前是把 URL 拼进上面那段文本里，用户得手动复制一长串地址去浏览器，
    // 手机上很难操作。改成单独的、可点击的条目，直接交给系统浏览器。
    // 用外部浏览器而不是内置 WebView：能复用已有的 Tailscale 登录态，
    // 也不必为一个第三方登录页维护内嵌浏览器和回调检测。
    if (status.authUrl.isEmpty) {
      return [statusItem];
    }
    return [
      statusItem,
      ListItem(
        leading: const Icon(Icons.open_in_new),
        title: Text(t('loginUrl')),
        subtitle: Text(
          '${t('loginUrlDesc')}\n${status.authUrl}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        onTap: () => _openLoginUrl(status.authUrl),
      ),
    ];
  }

  Future<void> _openLoginUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) {
      globalState.showNotifier('invalid login url: $url');
      return;
    }
    try {
      if (!await canLaunchUrl(uri)) {
        globalState.showNotifier('no browser available for $url');
        return;
      }
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      commonPrint.warn('open login url failed: $e');
      if (mounted) {
        globalState.showNotifier('$e');
      }
    }
  }

  /// 认证状态文案。
  ///
  /// 分开表达两层含义：
  ///   Auth Key / OAuth → 已登录，并说明用的是哪种方式；
  ///   未登录           → 从没授权过；
  ///   登录已过期       → 授权过但凭证失效，需要重新点登录链接。
  String _authStatusText(
    TailscaleAuthStatus status,
    String Function(String key) t,
  ) {
    switch (status) {
      case TailscaleAuthStatus.authKey:
        return t('authByKey');
      case TailscaleAuthStatus.oauth:
        return t('authByOAuth');
      case TailscaleAuthStatus.notLoggedIn:
        return t('authNone');
      case TailscaleAuthStatus.expired:
        return t('authExpired');
      case TailscaleAuthStatus.loggingIn:
        return t('authInProgress');
      case TailscaleAuthStatus.unknown:
        return t('authUnknown');
    }
  }

  String _stateText(String state, String Function(String key) t) {
    switch (state) {
      case 'idle':
        return t('stateIdle');
      case 'starting':
        return t('stateStarting');
      case 'NeedsLogin':
        return t('stateNeedsLogin');
      case 'NeedsMachineAuth':
        return t('stateNeedsMachineAuth');
      case 'Running':
        return t('stateRunning');
      case 'Stopped':
        return t('stateStopped');
      case 'absent':
        return t('stateAbsent');
      case 'unsupported':
        return t('stateUnsupported');
      case 'error':
        return t('stateError');
      default:
        return state;
    }
  }
}

/// 该功能页的文案。
///
/// 没有写进 arb / 生成的 l10n 里，是为了避免手改 7 份
/// lib/l10n/intl/messages_*.dart；后续若要正式本地化，
/// 把这里的 key 搬到 arb 再跑一次 flutter_intl 即可。
const Map<String, Map<String, String>> _strings = {
  'enable': {'en': 'Tailscale', 'zh': 'Tailscale'},
  'enableDesc': {
    'en': 'Run a Tailscale node inside the core, side by side with the proxy',
    'zh': '在核心内运行 Tailscale 节点，与代理同时使用',
  },
  'status': {'en': 'Status', 'zh': '状态'},
  'refresh': {'en': 'Refresh', 'zh': '刷新'},
  'connect': {'en': 'Connect', 'zh': '连接'},
  'transport': {'en': 'Transport', 'zh': '连接方式'},
  'transportMode': {'en': 'Connection mode', 'zh': '连接模式'},
  'transportModeDesc': {
    'en': 'Direct only: control, DERP and WireGuard bypass the proxy and TUN',
    'zh': '仅直连：控制面、DERP、WireGuard 直接走物理网卡，不进代理也不进 TUN',
  },
  'node': {'en': 'Node', 'zh': '节点'},
  'nodeName': {'en': 'Proxy name', 'zh': '节点名称'},
  'nodeNameDesc': {
    'en': 'Used as the routing-rule target for tailnet traffic',
    'zh': '作为 tailnet 流量的规则 target（不出现在代理列表里）',
  },
  'hostname': {'en': 'Hostname', 'zh': '主机名'},
  'hostnameDesc': {
    'en': 'Node name inside the tailnet',
    'zh': '在 tailnet 里显示的设备名',
  },
  'hostnameHint': {'en': 'System hostname', 'zh': '默认使用系统主机名'},
  'authKey': {'en': 'Auth key', 'zh': 'Auth Key'},
  'authKeyDesc': {
    'en': 'Recommended: log in without interaction',
    'zh': '推荐填写，免交互登录',
  },
  'controlUrl': {'en': 'Control URL', 'zh': '控制面地址'},
  'controlUrlDesc': {
    'en': 'Leave empty for Tailscale, set it for Headscale',
    'zh': '留空用官方控制面，自建 Headscale 时填写',
  },
  'exitNode': {'en': 'Exit node', 'zh': '出口节点'},
  'exitNodeDesc': {
    'en': 'Use another node as internet exit (optional)',
    'zh': '用另一台设备作为出口（可选）',
  },
  'exitNodeHint': {'en': 'auto:any or node IP', 'zh': 'auto:any 或节点 IP'},
  'routing': {'en': 'Routing', 'zh': '路由'},
  'routeRules': {'en': 'Inject tailnet rules', 'zh': '自动注入 tailnet 规则'},
  'routeRulesDesc': {
    'en': 'Send 100.64.0.0/10, fd7a:115c:a1e0::/48 and *.ts.net into Tailscale',
    'zh': '把 100.64.0.0/10、fd7a:115c:a1e0::/48、*.ts.net 交给 Tailscale',
  },
  'magicDns': {'en': 'MagicDNS', 'zh': 'MagicDNS'},
  'magicDnsDesc': {
    'en': 'Resolve ts.net via Tailscale DNS (needs DNS enabled)',
    'zh': '用 Tailscale DNS 解析 ts.net（需要开启 DNS）',
  },
  'dnsSuffix': {'en': 'Extra DNS suffix', 'zh': '额外域名后缀'},
  'dnsSuffixDesc': {
    'en': 'For Headscale split DNS, e.g. tailnet.example.com',
    'zh': 'Headscale 自定义域名时使用',
  },
  'acceptRoutes': {'en': 'Accept routes', 'zh': '接受子网路由'},
  'acceptRoutesDesc': {
    'en': 'Accept subnet routes advertised by subnet routers',
    'zh': '接受 subnet router 宣告的网段',
  },
  'exitNodeAllowLan': {'en': 'Exit node LAN access', 'zh': '出口节点允许局域网'},
  'exitNodeAllowLanDesc': {
    'en': 'Keep LAN reachable while using an exit node',
    'zh': '使用出口节点时仍可访问局域网',
  },
  'udp': {'en': 'UDP', 'zh': 'UDP'},
  'udpDesc': {
    'en': 'Allow UDP through the Tailscale outbound',
    'zh': '允许通过 Tailscale 出站转发 UDP',
  },
  'ephemeral': {'en': 'Ephemeral node', 'zh': '临时节点'},
  'ephemeralDesc': {
    'en': 'Remove the node from the tailnet when it goes offline',
    'zh': '离线后自动从 tailnet 移除',
  },
  'notes': {'en': 'Notes', 'zh': '说明'},
  'noteOneVpn': {'en': 'Only one VPN', 'zh': '只有一个 VPN'},
  'noteOneVpnDesc': {
    'en': 'Tailscale runs in userspace inside Bettbox, so the official Tailscale app must stay off',
    'zh': 'Tailscale 在 Bettbox 进程内以用户态运行，官方 Tailscale App 需要关闭',
  },
  'noteMagicDns': {'en': 'MagicDNS needs DNS', 'zh': 'MagicDNS 依赖 DNS'},
  'noteMagicDnsDesc': {
    'en': 'Enable DNS override, otherwise only IP / rule based access works',
    'zh': '需要开启 DNS 覆写，否则只能用 IP 或规则直接访问',
  },
  'statusUnknown': {'en': 'Not queried yet', 'zh': '尚未获取状态'},
  'statusIdleHint': {'en': 'Tap Connect to start the node', 'zh': '点「连接」启动节点'},
  'statusAuthHint': {
    'en': 'Fill in an auth key, or start the node and open the login URL',
    'zh': '填写 Auth Key，或启动后打开登录链接',
  },
  'state': {'en': 'State', 'zh': '状态'},
  'tailnetIp': {'en': 'Tailnet IP', 'zh': 'Tailnet IP'},
  'peers': {'en': 'Peers', 'zh': '节点数'},
  'authStatus': {'en': 'Auth', 'zh': '认证状态'},

  // ---- 多凭证 ----
  'credentials': {'en': 'Login credentials', 'zh': '登录凭证'},
  'credentialSaved': {'en': 'Saved', 'zh': '已保存'},
  'credentialCurrent': {'en': 'Current', 'zh': '当前凭证'},
  'credentialNone': {'en': 'None selected', 'zh': '未选择'},
  'credentialNoneDesc': {
    'en': 'Add or select a credential in "Manage credentials" above first',
    'zh': '请先在上方「管理登录凭证」中添加或选择一个凭证',
  },
  'addCredential': {'en': 'Manage credentials', 'zh': '管理登录凭证'},
  'addCredentialDesc': {
    'en': 'Add, switch or remove Tailscale logins',
    'zh': '添加、切换或删除 Tailscale 登录',
  },
  'addByAuthKey': {'en': 'Use auth key', 'zh': '用 Auth Key 登录'},
  'addByAuthKeyDesc': {
    'en': 'Non-interactive: paste a key generated in the admin console',
    'zh': '免交互：粘贴后台生成的 auth key',
  },
  'addByOAuth': {'en': 'Sign in with browser', 'zh': '浏览器授权登录'},
  'addByOAuthDesc': {
    'en': 'Open the Tailscale login page and authorize this device',
    'zh': '打开 Tailscale 登录页完成授权',
  },
  'credentialLabel': {'en': 'Name', 'zh': '凭证名称'},
  'credentialLabelHint': {'en': 'e.g. Work, Personal', 'zh': '例如：工作、个人'},
  'credentialAdded': {'en': 'Credential saved', 'zh': '凭证已保存'},
  'credentialRemove': {'en': 'Delete credential?', 'zh': '删除这个凭证？'},
  'credentialSwitch': {'en': 'Switch credential?', 'zh': '切换凭证？'},
  'credentialSwitchDesc': {
    'en': 'Switching restarts the VPN service. Current connections will drop.',
    'zh': '切换会重启 VPN 服务，当前连接会短暂中断。',
  },
  'credentialRemoveDesc': {
    'en': 'Signs out and deletes this saved login. The device may remain listed in the Tailscale admin console.',
    'zh': '会登出并删除这条登录。Tailscale 后台可能仍留有该设备记录，需手动清理。',
  },
  'oauthHint': {'en': 'Browser sign-in required', 'zh': '需要浏览器授权'},
  'oauthNeedVpn': {'en': 'Turn on VPN first', 'zh': '请先开启 VPN'},
  'oauthNeedVpnDesc': {
    'en': 'Tailscale runs inside the core, so the VPN must be on before a login link can be issued. Turn it on from the Home page, then tap this button again.',
    'zh': 'Tailscale 运行在内核中，需要 VPN 开启后才会启动并下发登录链接。请到首页开启 VPN，再回到这里点击该按钮。',
  },
  'oauthWaiting': {
    'en':
        'Node starting, the login link will appear on the status card shortly',
    'zh': '节点启动中，登录链接稍后会出现在状态卡片里',
  },
  'credentialEmpty': {'en': 'No credentials yet', 'zh': '还没有凭证'},
  'credentialEmptyDesc': {
    'en': 'Add one above to sign in to Tailscale',
    'zh': '在上方添加一个即可登录 Tailscale',
  },
  'cancel': {'en': 'Cancel', 'zh': '取消'},
  'confirm': {'en': 'Confirm', 'zh': '确认'},
  'authByKey': {'en': 'Auth Key', 'zh': 'Auth Key（免交互）'},
  'authByOAuth': {'en': 'Browser login', 'zh': '浏览器授权登录'},
  'authNone': {'en': 'Not signed in', 'zh': '未登录'},
  'authExpired': {'en': 'Session expired, sign in again', 'zh': '登录已过期，需重新授权'},
  'authInProgress': {'en': 'Signing in...', 'zh': '正在登录…'},
  'authUnknown': {'en': 'Unknown', 'zh': '未知'},
  'loginUrl': {'en': 'Login URL', 'zh': '登录链接'},
  'loginUrlDesc': {
    'en': 'Tap to authorize in your browser',
    'zh': '点击在浏览器中完成授权',
  },
  'health': {'en': 'Health', 'zh': '健康检查'},
  'error': {'en': 'Error', 'zh': '错误'},
  'stateIdle': {'en': 'Not started', 'zh': '未启动'},
  'stateStarting': {'en': 'Starting', 'zh': '启动中'},
  'stateNeedsLogin': {'en': 'Needs login', 'zh': '需要登录'},
  'stateNeedsMachineAuth': {'en': 'Needs approval', 'zh': '等待设备批准'},
  'stateRunning': {'en': 'Running', 'zh': '运行中'},
  'stateStopped': {'en': 'Stopped', 'zh': '已停止'},
  'stateAbsent': {'en': 'Not configured', 'zh': '未配置'},
  'stateUnsupported': {'en': 'Not built in', 'zh': '当前构建未包含'},
  'stateError': {'en': 'Error', 'zh': '出错'},
};

/// 「登录凭证」列表页：添加 / 切换 / 删除。
///
/// 为什么单独做一个页面而不是直接放在主页面里：凭证可能有多个，
/// 主页面已经很长了，而且在列表里做「切换」比塞一堆 RadioButton 清楚。
class _CredentialListView extends StatefulWidget {
  const _CredentialListView({required this.master, required this.t});

  final _TailscaleListViewState master;
  final String Function(String key) t;

  @override
  State<_CredentialListView> createState() => _CredentialListViewState();
}

class _CredentialListViewState extends State<_CredentialListView>
    with WidgetsBindingObserver {
  String Function(String key) get t => widget.t;

  /// 首次授权状态是否已拉取完成。
  ///
  /// 用来避免「进页面先闪一下『需要浏览器授权』」：
  /// _authorized 初始是空的，而不存在 == false，所以未加载完就渲染
  /// 会让所有 OAuth 凭证先显示成未授权，等异步结果回来再变。
  bool _authLoaded = false;

  /// 各凭证是否已经授权成功过（key 为 state-dir）。
  ///
  /// 用 hadProfile 而不是 p.hasAuthKey：OAuth 凭证本来就没有 key，
  /// 用有没有 key 判断会让它们永远显示「需要浏览器授权」，
  /// 哪怕早就登录好了。
  final Map<String, bool> _authorized = {};

  /// 防止 _refreshAuthStates 重入。
  bool _refreshingAuth = false;

  /// 进入后台的时刻。用来区分「真的去了别的 App」和「只是弹了输入法」。
  DateTime? _pausedAt;

  /// 拉一遍所有凭证的授权状态。
  /// 重新读取各凭证的授权状态。
  ///
  /// 三重保护，避免「输入法弹出」这类无关的 resume 造成掉帧：
  ///   1. 防重入：正在刷新时直接返回；
  ///   2. 结果未变则不 setState，避免无意义重建；
  ///   3. 一次取完所有值再统一提交，减少中间帧。
  Future<void> _refreshAuthStates() async {
    if (_refreshingAuth) return;
    _refreshingAuth = true;
    try {
      final manager = TailscaleConfigManager.instance;
      final next = <String, bool>{};
      for (final p in manager.profiles) {
        next[p.id] = await manager.hadProfile(p.resolvedStateDir);
      }
      _authLoaded = true;
      if (!mounted) return;
      if (next.length == _authorized.length &&
          next.entries.every((e) => _authorized[e.key] == e.value)) {
        return;
      }
      setState(() {
        _authorized
          ..clear()
          ..addAll(next);
      });
    } finally {
      _refreshingAuth = false;
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshAuthStates());
  }

  @override
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _pausedAt = DateTime.now();
      return;
    }
    if (state != AppLifecycleState.resumed) return;
    // 输入法弹出只是短暂的 inactive，不会经历 paused。
    // 之前直接在这里刷新，结果每弹一次键盘就跑一轮 prefs IO + setState，
    // 用户看到的就是「输入法弹出的那一刻掉帧」。
    // 用 paused 作标记，只有真正切到后台（浏览器授权、桌面）才刷新。
    final pausedAt = _pausedAt;
    _pausedAt = null;
    if (pausedAt == null) return;
    if (DateTime.now().difference(pausedAt) < const Duration(seconds: 2)) {
      return;
    }
    _refreshAuthStates();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 不套 CommonScaffold：外层 NextDelegate 已经提供了标题栏和返回键，
    // 再套一层会出现两个返回按钮 + 两个标题。
    return _buildBody();
  }

  /// 打开某个 OAuth 凭证的浏览器授权入口。
  ///
  /// 先把这个凭证切为当前（不弹「切换」确认——用户是主动点「去登录」的），
  /// 再等状态里出现 auth-url，然后交给系统浏览器。
  ///
  /// 为什么要这个按钮：非 auth-key 的凭证创建后不会自动跳转，
  /// 用户得自己回状态卡片找登录链接。对第一次用的人不可发现，
  /// 所以在刚添加的那条凭证上直接给出入口。
  Future<void> _openBrowserLogin(
    TailscaleProfile profile,
    String Function(String key) t,
  ) async {
    // 切换凭证会重建内核，_status 在那之后一段时间里还是旧值。
    // 直接把旧值拿去判断「是不是已经 Running」会误判——上一个凭证
    // 登录着的时候，这里会立刻 return，用户根本拿不到新凭证的登录链接。
    // 所以先把状态清空，强制等一轮真实的查询结果。
    // Tailscale 出站依附于内核，而内核依附于 VPN 服务。
    // VPN 没开时拿不到 auth-url，与其干等 12 秒后弹一句含糊的提示，
    // 不如直接说清楚要做什么。
    final isCoreRunning = widget.master.isCoreRunning;
    if (!isCoreRunning) {
      await globalState.showMessage(
        title: t('oauthNeedVpn'),
        message: TextSpan(text: t('oauthNeedVpnDesc')),
        cancelable: false,
      );
      return;
    }

    await widget.master._activateProfile(profile);
    if (!mounted) return;

    // 把「授权状态」也一并刷新，避免用旧目录的结论判断新凭证。
    widget.master.resetStatusForSwitch();

    // 给节点时间完成 control 握手，auth-url 才会出现。
    for (var i = 0; i < 15; i++) {
      if (!mounted) return;
      await widget.master._refreshStatus();
      if (!mounted) return;
      final status = widget.master.currentStatus;
      if (status == null) {
        await Future.delayed(const Duration(milliseconds: 800));
        continue;
      }
      final url = status.authUrl;
      if (url.isNotEmpty) {
        await widget.master._openLoginUrl(url);
        await _refreshAuthStates();
        return;
      }
      if (status.state == 'Running') {
        // 新凭证已经在运行，说明登录态还在（state-dir 复用），无需授权。
        await _refreshAuthStates();
        globalState.showNotifier(t('credentialAdded'));
        return;
      }
      await Future.delayed(const Duration(milliseconds: 800));
    }
    if (!mounted) return;
    globalState.showNotifier(t('oauthWaiting'));
    await _refreshAuthStates();
  }

  Widget _buildBody() {
    final manager = TailscaleConfigManager.instance;
    final profiles = manager.profiles;
    final activeId = manager.activeProfileId;
    return ListView(
      children: [
        ...generateSection(
          items: [
            ListItem.next(
              leading: const Icon(Icons.vpn_key_outlined),
              title: Text(t('addByAuthKey')),
              subtitle: Text(t('addByAuthKeyDesc')),
              delegate: NextDelegate(
                title: t('addByAuthKey'),
                builder: (_) => _PushOnBuild(
                  builder: () async {
                    await widget.master._addByAuthKey(t);
                    await _refreshAuthStates();
                    if (mounted) Navigator.of(context).pop();
                  },
                ),
              ),
            ),
            ListItem.next(
              leading: const Icon(Icons.open_in_browser_outlined),
              title: Text(t('addByOAuth')),
              subtitle: Text(t('addByOAuthDesc')),
              delegate: NextDelegate(
                title: t('addByOAuth'),
                builder: (_) => _PushOnBuild(
                  builder: () async {
                    await widget.master._addByOAuth(t);
                    await _refreshAuthStates();
                    if (mounted) Navigator.of(context).pop();
                  },
                ),
              ),
            ),
          ],
        ),
        if (profiles.isEmpty)
          ...generateSection(
            items: [
              ListItem(
                leading: const Icon(Icons.info_outline),
                title: Text(t('credentialEmpty')),
                subtitle: Text(t('credentialEmptyDesc')),
              ),
            ],
          )
        else
          ...generateSection(
            title: t('credentialSaved'),
            actions: [
              IconButton(
                tooltip: t('refresh'),
                icon: const Icon(Icons.refresh),
                // 手动刷新授权状态。
                //
                // 已经靠「回到前台」自动刷新了，但浏览器授权流程有时会在
                // 页面还没切走时就完成（例如授权页直接关闭），此时不会触发
                // resumed。留一个手动入口，让用户能立刻看到最新状态。
                onPressed: _refreshAuthStates,
              ),
            ],
            items: [
              for (final p in profiles)
                ListItem(
                  leading: Icon(
                    p.id == activeId
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                  ),
                  title: Text(p.label),
                  subtitle: Text(
                    // 还没拿到授权状态时，只显示登录方式，
                    // 不显示「需要浏览器授权」——否则进页面会先闪一下提示，
                    // 等异步结果回来又消失。宁可短暂少显示，也别给错信息。
                    !_authLoaded
                        ? (p.hasAuthKey ? t('authByKey') : t('authByOAuth'))
                        : _authorized[p.id] == true
                        // 已授权：只显示方式。
                        ? (p.hasAuthKey ? t('authByKey') : t('authByOAuth'))
                        // 未授权：OAuth 需要提示去浏览器授权。
                        : (p.hasAuthKey
                              ? t('authByKey')
                              : '${t('authByOAuth')}\n${t('oauthHint')}'),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 非 auth-key 的凭证没有 key 能填，只能走浏览器授权。
                      // 直接在这条凭证上给入口，省得让用户回状态卡片里找链接
                      // ——第一次用的人根本不知道该去哪点。
                      // 只有「未授权且不是 key 凭证」才需要跳浏览器。
                      if (_authLoaded &&
                          !p.hasAuthKey &&
                          _authorized[p.id] != true)
                        IconButton(
                          icon: const Icon(Icons.open_in_browser),
                          tooltip: t('oauthHint'),
                          onPressed: () => _openBrowserLogin(p, t),
                        ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () async {
                          await widget.master._removeProfile(p, t);
                          if (mounted) setState(() {});
                        },
                      ),
                    ],
                  ),
                  onTap: () async {
                    await widget.master._activateProfile(p, confirm: true);
                    if (mounted) setState(() {});
                  },
                ),
            ],
          ),
      ],
    );
  }
}

/// 在 build 时执行一次异步动作再退出的占位组件。
///
/// NextDelegate 需要一个 Widget，但我们的动作是「弹对话框 → 完成后关闭」，
/// 所以用一个触发式组件来承接。
class _PushOnBuild extends StatefulWidget {
  const _PushOnBuild({required this.builder});

  final Future<void> Function() builder;

  @override
  State<_PushOnBuild> createState() => _PushOnBuildState();
}

class _PushOnBuildState extends State<_PushOnBuild> {
  @override
  void initState() {
    super.initState();
    // 必须等页面转场动画结束再弹对话框。
    //
    // 之前用 addPostFrameCallback，那是「本页首帧画完」就执行，
    // 而此时 450ms 的 push 动画才刚起步。对话框的缩放淡入、
    // IdleAutofocusMixin 触发的输入法滑出，会和转场动画同时跑，
    // 三个动画叠在一起，每帧的 layout+paint 直接翻倍，表现为掉帧。
    unawaited(_waitRouteIdle());
  }

  Future<void> _waitRouteIdle() async {
    final route = ModalRoute.of(context);
    // 先等本帧结束，确保 route 已挂载。
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    // 再等转场动画播完（route.isCurrent 之后还要等 animation）。
    final animation = route?.animation;
    if (animation != null && animation.status != AnimationStatus.completed) {
      final done = Completer<void>();
      void listener(AnimationStatus status) {
        if (status == AnimationStatus.completed ||
            status == AnimationStatus.dismissed) {
          animation.removeStatusListener(listener);
          if (!done.isCompleted) done.complete();
        }
      }
      animation.addStatusListener(listener);
      await done.future;
      if (!mounted) return;
    }
    // 留一帧给转场收尾，避免下一帧同时处理收尾和对话框。
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    await widget.builder();
  }

  @override
  Widget build(BuildContext context) {
    return const SizedBox.shrink();
  }
}
