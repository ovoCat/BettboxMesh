import 'dart:async';

import 'package:bett_box/clash/clash.dart';
import 'package:bett_box/common/common.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/app.dart';
import 'package:bett_box/providers/config.dart';
import 'package:bett_box/providers/state.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/views/proxies/common.dart' show delayTestCoordinator;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class ClashManager extends ConsumerStatefulWidget {
  final Widget child;

  const ClashManager({super.key, required this.child});

  @override
  ConsumerState<ClashManager> createState() => _ClashContainerState();
}

class _ClashContainerState extends ConsumerState<ClashManager>
    with AppMessageListener {
  final List<TrackerInfo> _pendingRequests = [];
  static const _flushDuration = Duration(milliseconds: 300);
  static const _errorInterval = Duration(seconds: 10);
  final Map<String, DateTime> _errorNotified = {};

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }

  void _syncForeground() {
    clashCore.setForeground(!globalState.backgroundMode.value);
  }

  @override
  void initState() {
    super.initState();
    clashMessage.addListener(this);
    if (system.isAndroid) {
      globalState.backgroundMode.addListener(_syncForeground);
      unawaited(clashCore.preload().then((_) => _syncForeground()));
    }
    ref.listenManual(needSetupProvider, (prev, next) {
      if (prev != next) {
        final fullRestart =
            system.isDesktop &&
            prev?.a != next.a &&
            ref.read(networkSettingProvider).profileSwitchMode ==
                ProfileSwitchMode.fullRestart;
        unawaited(
          globalState.appController
              .handleChangeProfile(hardRestart: fullRestart)
              .catchError((Object error, StackTrace stackTrace) {
                commonPrint.error('Profile change failed: $error');
              }),
        );
      }
    });
    ref.listenManual(
      currentPageLabelProvider.select((state) => state == PageLabel.proxies),
      (prev, next) {
        if (next && prev == false) _refreshDelaySort();
      },
    );
    ref.listenManual(coreStateProvider, (prev, next) async {
      if (prev != next) {
        await clashCore.setState(next);
      }
    });
    ref.listenManual(updateParamsProvider, (prev, next) {
      if (prev != next) {
        globalState.appController.updateClashConfigDebounce();
      }
    });

    ref.listenManual(appSettingProvider.select((state) => state.openLogs), (
      prev,
      next,
    ) {
      if (!next) {
        clashCore.stopLog();
      }
    });
  }

  void _flushRequests() {
    if (!mounted || _pendingRequests.isEmpty) return;
    final requests = List.of(_pendingRequests);
    _pendingRequests.clear();
    ref.read(requestsProvider.notifier).addRequests(requests);
  }

  @override
  void dispose() {
    throttler.cancel(FunctionTag.requests);
    debouncer.cancel(FunctionTag.delaySort);
    clashMessage.removeListener(this);
    globalState.backgroundMode.removeListener(_syncForeground);
    super.dispose();
  }

  @override
  void onDelays(List<Delay> delays) {
    super.onDelays(delays);
    final appController = globalState.appController;
    for (final delay in delays) {
      appController.setDelay(delay);
    }
    debouncer.call(
      FunctionTag.delaySort,
      _refreshDelaySort,
      duration: const Duration(seconds: 5),
    );
  }

  void _refreshDelaySort() {
    if (!mounted || delayTestCoordinator.isTesting) return;
    final proxiesStyle = ref.read(proxiesStyleSettingProvider);
    if (proxiesStyle.sortType != ProxiesSortType.delay &&
        !proxiesStyle.hideTimeoutProxies) {
      return;
    }
    globalState.appController.addSortNum();
  }

  @override
  void onGroupsChanged() {
    super.onGroupsChanged();
    globalState.appController.updateGroupsDebounce();
  }

  void _notifyError(String text) {
    final now = DateTime.now();
    _errorNotified.removeWhere(
      (_, time) => now.difference(time) >= _errorInterval,
    );
    if (_errorNotified.containsKey(text)) return;
    _errorNotified[text] = now;
    globalState.showNotifier(text);
  }

  @override
  void onLog(Log log) {
    globalState.appController.addLog(log);
    // 内核日志默认只进内存环形缓冲，导出才能看到。开关打开时额外做两件事：
    //  1. 写 stdout —— 用 print 而不是 debugPrint（release 里后者是空操作），
    //     这样 `adb logcat -s flutter` 能实时看到；
    //  2. 写 debug.log —— 不依赖 logcat 缓冲区，事后可取完整日志。
    //
    // 注意：module 只在 payload 有 `[XXX]` 前缀时才解析得到，
    // 健康检查一类日志没有该前缀，直接拼 module 会打出 `[null]`。
    if (persistentLog) {
      final tag = log.module == null ? 'CORE' : 'CORE/${log.module}';
      // ignore: avoid_print
      print('[$tag] ${log.payload}');
      if (persistLogToFile) {
        writeDebugLog(tag, log.payload);
      }
    }
    if (log.logLevel == LogLevel.error) {
      _notifyError(log.payload);
    }
    super.onLog(log);
  }

  @override
  void onRequest(TrackerInfo trackerInfo) async {
    _pendingRequests.add(trackerInfo);
    throttler.call(
      FunctionTag.requests,
      _flushRequests,
      duration: _flushDuration,
    );
    super.onRequest(trackerInfo);
  }
}
