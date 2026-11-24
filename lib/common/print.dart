import 'dart:io';

import 'package:bett_box/common/constant.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/state.dart';

class CommonPrint {
  static CommonPrint? _instance;

  CommonPrint._internal();

  factory CommonPrint() {
    _instance ??= CommonPrint._internal();
    return _instance!;
  }

  void log(String? text) => _dispatch(text, LogLevel.info);

  void debug(String? text) => _dispatch(text, LogLevel.debug);

  void warn(String? text) => _dispatch(text, LogLevel.warning);

  void error(String? text) => _dispatch(text, LogLevel.error);

  void _dispatch(String? text, LogLevel level) {
    // 仅当打开 PERSISTENT_LOG 时才打到 stdout / 落盘：
    //  - 不能用 debugPrint —— release 构建里它什么都不输出；
    //  - 默认关闭时保持上游行为（日志只进内存环形缓冲）。
    if (persistentLog) {
      // ignore: avoid_print
      print('[APP] $text');
      if (persistLogToFile) {
        writeDebugLog('APP', text, level: level);
      }
    }
    if (!globalState.isInit) {
      return;
    }
    globalState.appController.addLog(Log.app('$text', level: level));
  }
}

/// 把一行日志追加到 `debug.log`。
///
/// 之所以要自己写文件而不是只靠 logcat：logcat 是环形缓冲，几分钟就被
/// 系统日志冲掉；而且内核日志只有在「日志」页面打开时才会推送
/// （见 core/hub.go 的 isStreamingLogs 判断），排查问题时经常拿不到。
void writeDebugLog(String tag, String? text, {LogLevel level = LogLevel.info}) {
  final path = debugLogPath;
  if (path == null) {
    return;
  }
  try {
    final line =
        '${DateTime.now().toIso8601String()} [${level.name}] [$tag] ${text ?? ''}\n';
    File(path).writeAsStringSync(line, mode: FileMode.append, flush: false);
  } catch (_) {
    // 写盘失败不能影响主流程
  }
}

/// 调试日志文件路径，由 `main()` 在确定应用目录后设置。
String? debugLogPath;

final commonPrint = CommonPrint();
