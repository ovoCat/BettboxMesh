const _useDevIdentity = bool.fromEnvironment('APP_DEV');
const _useStandardBuild = bool.fromEnvironment('APP_STANDARD');

class AppIdentity {
  static const isDev = _useDevIdentity;
  static const isStandard = _useStandardBuild;

  /// 产品名。同时用作：对外显示的品牌名、可执行文件名、核心库名、
  /// 数据目录名、服务名。因为要当文件名用，必须是不含特殊字符的纯字母。
  static const productName = 'BettboxMesh';

  static const devSuffix = 'Dev';
  static const packageId = 'com.appshub.bettbox.mesh';

  static const compactName = isDev ? '$productName$devSuffix' : productName;
  static const displayName = isDev ? '$productName Dev' : productName;
  static const mainExecutableName = productName;
  static const coreExecutableName = '${compactName}Core';
  static const dataDirName = compactName;
  static const tunDeviceName = compactName;
}

class WindowsHelperIdentity {
  static const serviceName = '${AppIdentity.compactName}HelperService';
  static const pipeName = '\\\\.\\pipe\\${AppIdentity.compactName}.Helper';
}
