import 'dart:math';
import 'dart:ui';

import 'package:collection/collection.dart';
import 'package:bett_box/common/common.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/state.dart';
import 'package:material_ui/material_ui.dart';

const appName = AppIdentity.displayName;
const appHelperService = WindowsHelperIdentity.serviceName;
const coreName = 'clash.meta';
const tunDeviceName = AppIdentity.tunDeviceName;
const browserUa =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36';
const packageName = AppIdentity.packageId;
final unixSocketPath = '/tmp/BettboxSocket_${Random().nextInt(10000)}.sock';
const maxTextScale = 1.2;
const minTextScale = 0.8;
final baseInfoEdgeInsets = EdgeInsets.symmetric(
  vertical: 16.ap,
  horizontal: 16.ap,
);

final defaultTextScaleFactor =
    WidgetsBinding.instance.platformDispatcher.textScaleFactor;
const httpTimeoutDuration = Duration(milliseconds: 5000);
const defaultDelayTestConcurrency = 64;
const maxDelayTestConcurrency = 128;
const moreDuration = Duration(milliseconds: 100);
const animateDuration = Duration(milliseconds: 100);
const midDuration = Duration(milliseconds: 200);
const commonDuration = Duration(milliseconds: 300);
const defaultUpdateDuration = Duration(days: 1);
const mmdbFileName = 'geoip.metadb';
const asnFileName = 'ASN.mmdb';
const geoSiteFileName = 'GeoSite.dat';
const bundleMRSFileName = 'BundleMRS.7z';
const bundleMRSRawUrl =
    'https://raw.githubusercontent.com/appshubcc/bett-rules/meta/';
final double kHeaderHeight = system.isDesktop ? 40 : 0;
const profilesDirectoryName = 'profiles';
const localhost = '127.0.0.1';
const clashConfigKey = 'clash_config';
const configKey = 'config';
const customSidebarIconKey = 'custom_sidebar_icon';
const customDashboardTitleKey = 'custom_dashboard_title';
const lastManagedScriptVersionKey = 'last_managed_script_version';
const restartAutoStartKey = 'restart_auto_start';
const double dialogCommonWidth = 300;
// 更新检查用的仓库（GitHub 的 owner/repo 形式）。
// 改这个之前请确认：
//   1. 仓库是 public —— 更新检查是匿名请求，私有仓库的 Release 下载需要 token；
//   2. 已经在仓库里创建了 Release，且 tag 形如 v1.19.9；
//   3. 上传的 asset 文件名与 updater.dart 里 assetName() 拼出来的一致。
const repository = 'ovoCat/BettboxMesh';
const ipInfoToken = String.fromEnvironment('IPINFO_TOKEN', defaultValue: '');
const defaultExternalControllerPort = 9090;
const maxMobileWidth = 600;
const maxLaptopWidth = 840;
/// 悬浮导航栏 + 系统手势条需要预留的高度。
///
/// 只用 viewPadding，不能用 padding —— 键盘弹出时 padding.bottom 会被
/// viewInsets 吃掉（变成 0），这个值随之变化，于是 ScrollBar 外层的
/// MediaQuery 和 ListView 的 padding 都变，整个列表重建。
/// 用户看到的就是「输入法弹出的那一刻掉帧」。
/// viewPadding 是系统栏占位，和键盘无关，键盘弹起时不会变。
double getFloatingBottomBarReserveHeight(BuildContext context) {
  if (globalState.isAndroidTV) return 0;
  final viewBottom = MediaQuery.viewPaddingOf(context).bottom;
  return 84.0 + (viewBottom > 12 ? viewBottom - 12 : 0);
}

double getFloatingBottomBarFABReserveHeight(BuildContext context) {
  if (globalState.isAndroidTV) return 0;
  final viewBottom = MediaQuery.viewPaddingOf(context).bottom;
  return 84.0 - min(viewBottom, 12.0);
}

const defaultTestUrl = 'https://www.gstatic.com/generate_204';

// Preset test URLs
const presetTestUrls = [
  'https://g.cn/generate_204',
  'https://www.gstatic.com/generate_204',
  'https://www.google.com/generate_204',
  'https://cp.cloudflare.com/generate_204',
  'https://www.apple.com/library/test/success.html',
];

// Preset NTP servers
const defaultNtpServer = 'ntp.aliyun.com';
const presetNtpServers = [
  'ntp.aliyun.com',
  'time.apple.com',
  'ntp.tencent.com',
  'time.windows.com',
  'time.cloudflare.com',
];

class CommonFilters {
  static final ImageFilter blur = ImageFilter.blur(
    sigmaX: 2,
    sigmaY: 2,
    tileMode: TileMode.mirror,
  );
}

final commonFilter = CommonFilters.blur;

const navigationItemListEquality = ListEquality<NavigationItem>();
const trackerInfoListEquality = ListEquality<TrackerInfo>();
const stringListEquality = ListEquality<String>();
const intListEquality = ListEquality<int>();
const logListEquality = ListEquality<Log>();
const groupListEquality = ListEquality<Group>();
const externalProviderListEquality = ListEquality<ExternalProvider>();
const packageListEquality = ListEquality<Package>();
const hotKeyActionListEquality = ListEquality<HotKeyAction>();
const stringAndStringMapEquality = MapEquality<String, String>();
const stringAndStringMapEntryIterableEquality =
    IterableEquality<MapEntry<String, String>>();
const delayMapEquality = MapEquality<String, Map<String, int?>>();
const stringSetEquality = SetEquality<String>();
const keyboardModifierListEquality = SetEquality<KeyboardModifier>();

const viewModeColumnsMap = {
  ViewMode.mobile: [2, 1],
  ViewMode.laptop: [3, 2],
  ViewMode.desktop: [4, 3],
};

const proxiesListStoreKey = PageStorageKey<String>('proxies_list');
const toolsStoreKey = PageStorageKey<String>('tools');
const profilesStoreKey = PageStorageKey<String>('profiles');

const defaultPrimaryColor = 0xFF00897B;

const maxLength = 1024;

/// 日志环形缓冲容量。
///
/// 原来是 512，但 debug 级别下 DNS 解析一次能刷出几十行（一个页面加载就能
/// 打满整个 buffer），Tailscale / 内核对这种「启动阶段才打几条」的日志会被
/// 后续流量直接挤掉，排查时只能看到最近十几秒的内容。放宽到 4096。
const maxLogLength = 4096;

// ---------------------------------------------------------------------------
// BettboxMesh 调试开关
//
// 这些是相对于上游的「可选增强」，默认关闭即与上游行为一致。
// 编译自己的包时用 --dart-define 打开：
//
//   flutter build apk --dart-define=PERSISTENT_LOG=true
//
// 好处：升级上游时这些改动可以直接接受上游版本，只有需要时再打开，
// 不必让补丁成为强依赖。
// ---------------------------------------------------------------------------

/// 常驻开启内核日志流。
///
/// core/hub.go 的 ensureLogSubscriber 里，非 ERROR 级日志只有在
/// isStreamingLogs 为 true（由 startLog 置位）时才推送，而原本只有
/// 打开「日志」页面才会 startLog，页面一关就 stopLog。开启后日志流
/// 常驻，配合 onLog 里的 stdout + debug.log 落盘，`adb logcat` 随时
/// 能看到内核（含 Tailscale）的完整日志。
///
/// 默认 false：与上游行为一致（日志只进内存环形缓冲）。
const persistentLog = bool.fromEnvironment('PERSISTENT_LOG', defaultValue: false);

/// 把内核日志额外写入 `files/debug.log`，并把 App 日志也打进 stdout。
///
/// release 构建里 `debugPrint` 是空操作，`print` 也不会进 logcat，
/// 所以排查 release 包问题时需要自己落盘。依赖 [persistentLog] 才有内容。
const persistLogToFile = bool.fromEnvironment('PERSIST_LOG_FILE', defaultValue: false);

final mainIsolate = 'BettboxMainIsolate';

final serviceIsolate = 'BettboxServiceIsolate';

const defaultPrimaryColors = [
  0xFF1E293B,
  0xFF1976D2,
  defaultPrimaryColor,
  0xFFE91E63,
  0xFF7B1FA2,
  0xFFD97706,
  0xFF4F46E5,
  0xFF008FB6,
  0xFF388E3C,
  0xFF827717,
  0xFF795548,
];

const legacyPrimaryColors = [
  0xFF1E293B,
  0xFF1976D2,
  defaultPrimaryColor,
  0xFFE91E63,
  0xFF7B1FA2,
  0xFFD97706,
  0xFF334155,
];

const scriptTemplate = '''
const main = (config) => {
  return config;
}''';
