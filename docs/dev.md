# 开发者指南

面向要继续开发这个分支的人（或 AI 助手）。

本项目是 [Bettbox](https://github.com/appshubcc/Bettbox) 的分支，核心增强是**在代理运行的同时使用 Tailscale**。其余功能与上游一致。

> 上游已有完整骨架（订阅、规则、TUN、面板），本分支只动两处：
> **加 Tailscale** 和 **围绕它做的可用性改造**。

---

## 一、先理解三条硬约束

这三条是架构前提，不理解会写出必然失败的代码。

### 1. Android 同时只能有一个 VpnService

代理 TUN 已占用它，官方 Tailscale App 无法同时运行。

→ Tailscale 必须以 **userspace netstack**（`tsnet`）形式编译进 core，
跑在同一个进程里，不申请第二个 VPN 授权。

### 2. Tailscale 底层流量必须直连

控制面 HTTPS、DERP、WireGuard 这些「非 tailnet」的 socket，
全部走物理网卡，**不进代理也不进 TUN**。

**不支持「走代理」**。原因：tsnet 的 magicsock 需要一个能自由发包的通用 UDP socket
（它要先 bind 本地端口再用 STUN 发现映射），而 mihomo 的
`proxydialer.ListenPacket` 只能在已知目标地址时建立 UDP 关联。
接上去 node 直接起不来，报：

```
magicsock: Rebind IPv4 failed: failed to bind any ports (tried [0])
```

曾经实现过 `dialer-proxy` 走代理，就是这个错误。现在 `patchTailscale`
不写该字段，配置里若残留只打 warning 并忽略。

### 3. 注入型配置必须走 `setupConfig`

core 有两条配置下发路径，**语义完全不同**：

| 路径 | 作用 | 碰 proxies/rules/dns 吗 |
| --- | --- | --- |
| `updateConfig()` | 只改运行时字段（端口 / 模式 / 日志级别） | ❌ **完全不碰** |
| `setupConfig()` | 重新解析 rawConfig，重建 tunnel | ✅ 是唯一入口 |

**这是本项目踩过的最大的坑。** Tailscale 开关最初走 `updateConfig`，
表现是「必须重启 App 才生效」+「关掉开关却不生效」——因为出站和规则
压根没被重新注入。

现在 UI 的 `_save()` 会调 `restartCore()`（内部走 `setupConfig`），
并配合 `_tailscaleConfigRevision` 版本号确保改动被感知。

---

## 二、代码地图

### Go 侧（core）

| 文件 | 职责 |
| --- | --- |
| `core/tailscale_patch.go` | 把 UI 配置展开成 mihomo 的 `type: tailscale` 出站、tailnet 规则、MagicDNS 策略、FakeIP 绕行 |
| `core/tailscale_status.go` | 三个 action 的实现：状态查询 / 主动拉起 / 登出；以及配置生效后的预热与清理 |
| `core/patch.go` | `PatchParams.Tailscale` 接入点；tailscale 规则合并在 prepend-rules 之前 |
| `core/constant.go` / `core/action.go` | action 名注册与分发 |
| `core/common.go` | `hub.ApplyConfig` 之后调 `warmupTailscaleOutbounds()` 再 `pruneTailscaleOutbounds()` |
| `core/Clash.Meta/adapter/outbound/tailscale.go` | vendored 补丁：实例注册表、`Status()`、`StartAsync()`、`Logout()`、`CloseIdle()` |
| `core/Clash.Meta/adapter/outbound/tailscale_stub.go` | `no_tailscale` 轻量构建下的同名空实现 |

### Dart 侧

| 文件 | 职责 |
| --- | --- |
| `lib/models/tailscale.dart` | 配置模型、凭证模型、持久化、认证状态推导 |
| `lib/views/config/tailscale.dart` | 设置页 + 凭证管理页 |
| `lib/controller.dart` | `restartCore()`、配置版本号、更新流程 |
| `lib/state.dart` | 下发 patch 参数、`_withTailnetRoutes()` 修补 TUN 路由 |
| `lib/clash/*` + `lib/enum/enum.dart` | action 桥接（新增 action 后**必须**重跑 build_runner） |

---

## 三、配置是怎么注入的

UI 的配置最终变成这样一段 mihomo 配置：

```yaml
proxies:
  - name: Tailscale
    type: tailscale
    hostname: my-phone          # 留空用系统 hostname
    auth-key: tskey-auth-...    # 留空则需交互式登录
    control-url: ''             # 自建 Headscale 时填
    state-dir: tailscale-abc123
    ephemeral: false
    udp: true
    accept-routes: false
    exit-node: ''
    exit-node-allow-lan-access: false
    # 注意：不写 dialer-proxy

rules:
  # 注入在订阅规则最前面，避免被 GEOIP / MATCH 抢走
  - IP-CIDR,100.64.0.0/10,Tailscale,no-resolve
  - IP-CIDR6,fd7a:115c:a1e0::/48,Tailscale,no-resolve
  - DOMAIN-SUFFIX,ts.net,Tailscale

dns:
  nameserver-policy:
    +.ts.net: tailscale://Tailscale
  fake-ip-filter:
    - controlplane.tailscale.com
    - login.tailscale.com
    # ... 等 5 个控制面域名
```

### 几个关键细节

**不会加入 `proxy-groups`。** 它不是「可以选来上网的代理」，
放进组里容易误解，而且规则按名字直接引用未入组的出站即可。
副作用：**代理页看不到它**，这是设计如此。

**`no-resolve` 很重要。** 命中 IP 规则时不需要提前解析域名，
避免 `ts.net` 在规则匹配阶段被别的 DNS 解析成公网 IP。

**控制面域名必须进 `fake-ip-filter`。** 否则 FakeIP 会把
`controlplane.tailscale.com` 解析成 `198.18.x.x`，tsnet 去连一个不存在的
地址，登录永远超时。自建 Headscale 时，其域名也会被自动加入。

**`tailscale://<name>`** 是 mihomo 内置的 DNS scheme
（`dns/util.go` 里的 `case "tailscale"`），把查询转发给对应出站的 `QueryDNS`。

---

## 四、七个必须知道的陷阱

### 1. 编译 core 必须加 `--standard`

上游从 1.19.9 起把 `setup.dart` 的变体参数默认值从 `lite` 翻转成了标准版，
**不加参数会注入 `no_tailscale,no_easytier,no_zerotier,no_fake_tcp`**。

Tailscale 直接从 `libmeta.so` 里消失（39MB lite vs 63MB standard），
而 APK 照常能装能跑，只是 Tailscale 页永远显示「未配置」。

```bash
dart setup.dart android --arch arm64 --out core --standard
```

检查方法：`libclash/.tags/android-arm64-v8a` 内容应为 `with_gvisor`。

### 2. `IdleCloser` ≠ 删除节点

它的语义是「连接空闲释放传输资源」，mihomo 会在健康检查之后调用。

把 `CloseIdle()` 写成 `Close()` 会让刚登录成功的节点**十几秒后被杀**，
表现是「登录成功了但马上又变回未配置」。

清理已移除的出站应该放在 `setupConfig` 之后的 `pruneTailscaleOutbounds()`。

### 3. 改枚举后必须重跑 build_runner

```bash
dart run build_runner build --delete-conflicting-outputs
```

只要动过 `ActionMethod` / `PageLabel` 等被 json_serializable 覆盖的枚举，
不重新生成就会在**运行期**抛：

```
Converting object to an encodable object failed: Instance of '_Action'
```

验证：`lib/models/generated/core.g.dart` 的 `_$ActionMethodEnumMap`
应包含新增的方法名。实测踩过三次（1.19.8 / 1.19.9 / 1.20.1 各一次）。

### 4. 编 APK 必须加 `APP_ENV=stable`

```dart
isPre = const String.fromEnvironment('APP_ENV') != 'stable';
```

不加有两个后果：

1. 界面顶部显示 `PRE` 标记
2. `checkForUpdate()` 里相同版本也会提示更新
   （`hasUpdate = compared > 0 || (compared == 0 && isPreRelease)`）

### 5. 注入型配置必须走 `setupConfig`

core 有两条配置路径，作用范围完全不同：

| 路径 | 能力 |
| --- | --- |
| `updateClashConfig()` → `updateConfig()` | **只**改运行时字段：端口、模式、日志级别、IPv6 |
| `restartCore()` → `setupConfig()` | 重新解析 rawConfig、重建 tunnel、注入 proxies/rules/dns |

Tailscale 出站、tailnet 规则、MagicDNS、fake-ip-filter **全部只在
`setupConfig` 里生效**。最初 Tailscale 开关错走了 `updateConfig`，导致：
「首次填 Key 开启无效，必须重启 App」「关闭开关但旧出站没移除」。

**新增任何「注入型」配置时，务必确认它走 setupConfig。**

### 6. Rust 组件编译失败时 `flutter build apk` 仍返回 0

`plugins/code_forge`（脚本编辑器）通过 cargokit 编译 Rust。它失败时
**不会让 Flutter 构建失败**——退出码仍是 0，但 APK 里缺少
`libcode_forge.so`，装到设备上打开脚本编辑器会崩溃。

常见原因是 `LIBCLANG_PATH` 未设置（rquickjs 的 bindgen 需要它）。

**每次出包后必做检查**：

```bash
jar tf <apk> | grep libcode_forge   # 必须有输出
```

缺 `libcode_forge.so` 的包比正常包小约 1.25 MB。这个陷阱最危险的地方是
**没有任何报错中断构建**，只看退出码会漏掉。

---

### 7. Flutter 的 assets 声明不递归子目录

`pubspec.yaml` 里声明的目录**只包含该目录下的直接文件**，不含子目录：

```yaml
assets:
  - assets/images/avatars/          # 含 avatars/*.jpg
  - assets/images/avatars/bmc/      # 子目录必须单独声明
```

漏声明的表现很隐蔽：**编译成功、APK 正常、但图片显示不出来**
（运行时 `Unable to load asset`）。

**本项目实例**：`ovoCat` 的头像在 `assets/images/avatars/bmc/ovoCat.jpg`，
所以 `pubspec.yaml` 必须有对应的一行。上游的 `avatars/` 是平铺的、无子目录，
升级覆盖 `pubspec.yaml` 时**极易漏掉这一行**。

**验证**：

```bash
jar tf <apk> | grep avatars/bmc
```

应该看到 `assets/flutter_assets/assets/images/avatars/bmc/ovoCat.jpg`。

---

## 五、状态机怎么判断的

Tailscale 节点的 `State` 来自 tsnet 的 `ipn.State`，但直接用会误判。
实际映射逻辑：

| tsnet 状态 | UI 显示 | 说明 |
| --- | --- | --- |
| `Running` | 运行中 | 已连接 |
| `Starting` | 启动中 | 握手中 |
| `NeedsLogin` | 未登录 / 登录已过期 | **需要区分**：靠 `hadProfile` 标记 |
| `NeedsMachineAuth` | 需要管理员批准 | tailnet 开了设备审批 |
| `NoState` / `Stopped` | 登录已过期 | 常见于设备被后台删除 |
| `absent` | 未配置 | 出站尚未注入（VPN 未启动） |

### 认证状态为什么要单独记录

**登录方式不能靠当前配置推断。** tsnet 在删掉 auth-key 之后，
会话依然有效（登录态存在 `state-dir/tailscaled.state` 的 node key 里）。
用「当前有没有 key」判断，会让 OAuth 用户被误报成「需要浏览器授权」。

所以登录方式在**第一次观察到 `Running` 的那一刻**写入，
且只在 `unknown` 时写一次，之后不再覆盖。

同理，`hadProfile` 标记用来区分「从没登录过」和「登录过期了」。
auth-key 凭证在添加时即写入该标记（用户主动提供了凭证），
OAuth 凭证必须真正拿到 auth-url 并完成授权后才有标记。

---

## 六、构建

### 环境要求

- Flutter 3.50.1+（Dart 3.13+；1.20.1 起下限放宽到 3.13.0，实测 3.14.0 编译通过）
- Go 1.24+
- JDK 17
- Rust（core 里有 Rust 组件）
- LLVM / libclang（bindgen 需要，配 `LIBCLANG_PATH`）
- Android SDK 36 + NDK 28

### 命令

```bash
# 1) core（两个架构分别编，必须加 --standard）
dart setup.dart android --arch arm64 --out core --core-version alpha --standard
dart setup.dart android --arch amd64 --out core --core-version alpha --standard

# 2) APK
flutter build apk --release --target-platform android-arm64 --split-per-abi \
  --dart-define=APP_ENV=stable
```

**`APP_ENV=stable` 不能省。** 不传的话：

- 界面顶部会显示 `PRE` 标记
- `checkForUpdate()` 里相同版本也会提示更新
  （`hasUpdate = compared > 0 || (compared == 0 && isPreRelease)`）

### 签名

项目支持正式签名，四项齐全自动启用，缺任一项回退 debug 签名：

```
android/app/keystore.jks               ← keystore 文件
android/local.properties
  storePassword=...
  keyAlias=...
  keyPassword=...
```

**keystore 不要提交到仓库**（`.gitignore` 已覆盖 `*.jks` 和 `local.properties`）。

换签名后已安装的用户**必须卸载重装**，否则报：

```
INSTALL_FAILED_UPDATE_INCOMPATIBLE
```

### 调试开关

| 开关 | 默认 | 作用 |
| --- | --- | --- |
| `PERSISTENT_LOG` | false | 常驻内核日志流 |
| `PERSIST_LOG_FILE` | false | 额外落盘 `files/debug.log` |

订阅里的 `log-level: silent` 会**覆盖** App 设置。看日志前必须到
「内核配置 → 常规 → 日志等级」改成 Debug，否则 tsnet 内部日志（magicsock / derp）不会出现。

---

## 七、验证

```bash
dart analyze lib                              # Dart 静态检查
cd core && go vet -tags with_gvisor .         # Go 静态检查
cd core && go test -tags with_gvisor .        # Go 单测（含 9 个注入逻辑测试）
flutter test test/models/                     # Dart 单测（13 个认证状态测试）
```

### 改完 Tailscale 相关代码后，最小验证清单

1. **出站注入了吗**：VPN 开着时导出运行时配置，确认有 `type: tailscale`
2. **规则在最前面吗**：`IP-CIDR,100.64.0.0/10` 必须在订阅规则之前
3. **节点起来了吗**：日志里有 `state=Running ips=[100.x]`
4. **tailnet 通吗**：从设备 ping 一个 tailnet 内的 `100.x` 地址
5. **MagicDNS 通吗**：解析一个 `<device>.<tailnet>.ts.net`
6. **重启后还在吗**：杀掉 App 重开，配置和凭证应该都还在

第 6 项最容易漏——曾在「添加即用」的测试路径上漏掉，导致
「重启后凭证消失」的 bug 直到装了正式包才暴露（`ensureLoaded()` 从未被调用）。

---

## 八、性能注意点

这几处都表现为「界面掉帧」，根因各不相同。

### 1. `restartCore` 里的同步阻塞

切换/添加凭证会走 `restartCore()`，其中两处重操作要避免同步等待：

```dart
// ❌ 会卡
await clashCore.requestGc(forceFreeOSMemory: true);  // Go 的 debug.FreeOSMemory() 同步停顿
await updateGroups();                                // 遍历所有代理组
await updateProviders();                             // 拉取所有 provider

// ✅ 正确
await clashCore.requestGc();        // 普通 GC 足够
unawaited(updateGroups());          // 只是 UI 数据，不影响内核
unawaited(updateProviders());
```

但 `scheduleIdleGc()` / `_backgroundLoad()` / 后台模式 GC 里的
`forceFreeOSMemory: true` **保留不动**——它们在用户空闲时执行，停顿无感。

### 2. `MediaQuery.padding` 会随键盘变化

```dart
// ❌ 键盘一弹，padding.bottom 从「手势条高度」变成 0
final viewBottom = max(
  MediaQuery.viewPaddingOf(context).bottom,
  MediaQuery.paddingOf(context).bottom,   // ← 这个会变
);

// ✅ viewPadding 是系统栏占位，与键盘无关
final viewBottom = MediaQuery.viewPaddingOf(context).bottom;
```

值变化 → 外层 `MediaQuery` 数据变 → `ListView.padding` 变 → **整个列表重建**。
表现就是「输入法弹出的那一刻掉帧」。

### 3. 对话框不要和页面转场动画抢

`addPostFrameCallback` 只等「本页首帧画完」，而 450ms 的 push 转场才刚起步。
此时弹对话框 → 三个动画（转场 + 对话框缩放 + 键盘滑出）叠在一起，
每帧三份 layout + paint，60fps 预算直接超了。

正确做法：等 `ModalRoute.animation` 到 `completed` 再弹。

### 4. 生命周期回调会被输入法误触发

Android 弹软键盘会发 `inactive` → `resumed`。如果直接在 `resumed` 里刷新数据，
每次弹键盘都会跑一轮 IO + setState。

用 `paused` 作标记（弹键盘只走 `inactive`，不会 `paused`），就能区分
「真的切到后台」和「只是弹了输入法」。

---

## 九、升级上游

项目与上游 **没有共同祖先**（从 tarball 建立），所以
`git diff upstream/main HEAD` 会把整个仓库算成改动（2500+ 文件），没有参考价值。

正确做法是**在纯上游基线上重打补丁**，而不是 merge。

大致流程：

1. 拉取上游新版本到独立目录
2. 按「纯新增 → vendored 补丁 → 接线点 → 品牌定制」的顺序迁移
3. 每迁完一类就跑一次 `dart analyze` + `go test`
4. **第一件事先跑 build_runner**（见陷阱 3）
5. 用最小验证清单过一遍（见第七节）

修改集中在这些文件：

```
纯新增（零冲突）
  core/tailscale_patch.go
  core/tailscale_status.go
  core/tailscale_patch_test.go
  lib/models/tailscale.dart
  lib/views/config/tailscale.dart
  docs/*.md

vendored mihomo 补丁（中等风险）
  core/Clash.Meta/adapter/outbound/tailscale.go
  core/Clash.Meta/adapter/outbound/tailscale_stub.go

接线点（低风险，需逐一确认）
  core/patch.go  core/constant.go  core/action.go  core/common.go
  lib/enum/enum.dart  lib/clash/*.dart  lib/state.dart
  lib/common/navigation.dart  lib/views/config/config.dart  lib/controller.dart

品牌定制（低风险）
  lib/common/identity.dart
  android/app/build.gradle.kts
  android/app/src/*/AndroidManifest.xml
  android/app/src/main/res/values*/strings.xml
```

---

### 升级后必查：repository 与 assetName 会静默回退

1.20.1 升级时这两处被上游覆盖，**不产生编译错误**，只在功能层面失效：

```dart
// lib/common/constant.dart —— 检查更新的仓库地址
const repository = 'ovoCat/BettboxMesh';   // 必须是这个，不能是 appshubcc/Bettbox

// lib/common/updater.dart —— 下载 asset 名前缀
return '${AppIdentity.productName}-$version-$_assetSuffix';  // 跟随 productName
```

**后果**：检查更新会拉上游的 Release，提示用户下载官方 Bettbox，
永远收不到本项目的更新。所有 1.20.1 的 APK 都中招。

升级后自查：

```bash
Select-String -Path lib/common/constant.dart -Pattern "const repository"
Select-String -Path lib/common/updater.dart -Pattern "return.*assetSuffix"
```

---

### 升级时 README 类文件同样会被覆盖

**1.20.1 升级踩过**：`README.md` 和 `readme/` 目录被当作纯上游文件覆盖，
丢掉了标题（`BettboxMesh` → `Bettbox`）、「相对上游的差异」章节、「文档索引」
章节、项目热度指向（`ovoCat/BettboxMesh` → 上游），以及被删的多语言版本。

这类文件**不会引起编译错误**，所以最容易被忽略。

升级后必查：

```bash
Select-String -Path README.md -Pattern "BettboxMesh|Tailscale"   # 应全部命中
Get-ChildItem readme                                              # 应只剩 en + png
```

恢复：历史里一定有提交前的版本，`git show <commit>:README.md > README.md`。

---


## 十、贡献时请注意

**不要把敏感信息写进代码或文档。** 包括：

- keystore 文件、密码
- 真实的 Tailscale auth key
- 个人的 tailnet 名称、`100.x` 地址
- 本地绝对路径

测试用的伪造值请用明显的占位形式，例如 `tskey-auth-EXAMPLE`。

**改动前先看这个文档的第一节。** 三条硬约束踩中任何一条，
代码要么跑不起来，要么表现成「看起来能用但实际不生效」——后者更难排查。
