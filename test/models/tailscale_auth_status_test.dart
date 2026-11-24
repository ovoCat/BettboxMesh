import 'package:bett_box/models/tailscale.dart';
import 'package:flutter_test/flutter_test.dart';

/// 认证状态映射的单元测试。
///
/// 这套映射决定用户能否看懂自己处于什么状态，已经出过两次可见的问题：
///   1. NoState（设备被服务端删除）没覆盖，显示成「未知」；
///   2. 用「当前有没有 key」去猜登录方式，导致「用 key 登录后删掉 key」
///      被误显示成「浏览器授权登录」。
/// 所以这里把每种状态和每种登录方式都钉死。
void main() {
  TailscaleNodeStatus statusOf(String state) =>
      TailscaleNodeStatus(name: 'Tailscale', state: state);

  TailscaleAuthStatus resolve(
    String state, {
    TailscaleLoginMethod method = TailscaleLoginMethod.unknown,
    bool hadProfile = false,
  }) => statusOf(state).authStatus(
    loginMethod: method,
    hadProfileBefore: hadProfile,
  );

  group('已登录：以登录时记录的方式为准', () {
    test('Running + 记录了 authKey → authKey', () {
      expect(
        resolve('Running', method: TailscaleLoginMethod.authKey),
        TailscaleAuthStatus.authKey,
      );
    });

    test('Running + 记录了 oauth → oauth', () {
      expect(
        resolve('Running', method: TailscaleLoginMethod.oauth),
        TailscaleAuthStatus.oauth,
      );
    });

    // 回归：这就是用户踩到的场景——用 key 登录成功，之后把 key 从配置里
    // 删了。会话依然有效，但当前配置没有 key。若用「当前有没有 key」判断，
    // 会错误显示成「浏览器授权登录」。
    test('Running + 没有记录 → unknown（不编造方式）', () {
      expect(
        resolve('Running', method: TailscaleLoginMethod.unknown),
        TailscaleAuthStatus.unknown,
      );
    });
  });

  group('需要授权：按是否登录过区分「过期」和「未登录」', () {
    test('NeedsLogin + 登录过 → expired', () {
      expect(
        resolve('NeedsLogin', hadProfile: true),
        TailscaleAuthStatus.expired,
      );
    });

    test('NeedsLogin + 没登录过 → notLoggedIn', () {
      expect(resolve('NeedsLogin'), TailscaleAuthStatus.notLoggedIn);
    });

    test('NeedsMachineAuth + 登录过 → expired', () {
      expect(
        resolve('NeedsMachineAuth', hadProfile: true),
        TailscaleAuthStatus.expired,
      );
    });

    // 回归：设备在 Tailscale 后台被删除后 tsnet 报 NoState，
    // 曾经落到 default 显示「未知」。
    test('NoState + 登录过 → expired（设备被删除）', () {
      expect(resolve('NoState', hadProfile: true), TailscaleAuthStatus.expired);
    });

    test('NoState + 没登录过 → notLoggedIn', () {
      expect(resolve('NoState'), TailscaleAuthStatus.notLoggedIn);
    });

    test('Stopped + 登录过 → expired', () {
      expect(resolve('Stopped', hadProfile: true), TailscaleAuthStatus.expired);
    });
  });

  group('过渡状态', () {
    test('Starting → loggingIn', () {
      expect(resolve('Starting'), TailscaleAuthStatus.loggingIn);
      expect(resolve('starting'), TailscaleAuthStatus.loggingIn);
    });

    test('未知值 → unknown', () {
      expect(resolve('SomethingElse'), TailscaleAuthStatus.unknown);
      expect(resolve(''), TailscaleAuthStatus.unknown);
    });
  });

  group('语义辅助属性', () {
    test('只有 authKey/oauth 算已认证', () {
      expect(TailscaleAuthStatus.authKey.isAuthenticated, isTrue);
      expect(TailscaleAuthStatus.oauth.isAuthenticated, isTrue);
      expect(TailscaleAuthStatus.expired.isAuthenticated, isFalse);
      expect(TailscaleAuthStatus.notLoggedIn.isAuthenticated, isFalse);
      expect(TailscaleAuthStatus.unknown.isAuthenticated, isFalse);
    });

    test('未登录和过期才需要用户操作', () {
      expect(TailscaleAuthStatus.notLoggedIn.needsUserAction, isTrue);
      expect(TailscaleAuthStatus.expired.needsUserAction, isTrue);
      expect(TailscaleAuthStatus.authKey.needsUserAction, isFalse);
      expect(TailscaleAuthStatus.oauth.needsUserAction, isFalse);
      expect(TailscaleAuthStatus.loggingIn.needsUserAction, isFalse);
    });
  });
}
