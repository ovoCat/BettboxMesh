# Tailscale 集成

目标：**在开着代理的同时用 Tailscale**。

Tailscale 自身的底层流量（控制面 HTTPS、DERP、WireGuard）**始终直连物理网卡**，
不进代理也不进 TUN。**不支持「走代理」**，原因见「关键约束」第 3 条
（tsnet 的 magicsock 需要通用 UDP socket，而 mihomo 的 proxydialer
只能定向建 UDP 关联，接上去节点直接起不来）。

本文档是实现说明 + 使用说明。代码分布：

| 位置 | 作用 |
| --- | --- |
| `core/tailscale_patch.go` | 把 UI 配置展开成 mihomo 的 `type: tailscale` 出站、tailnet 规则、MagicDNS 策略 |
| `core/tailscale_status.go` | 状态查询 / 主动拉起 / 登出 三个 action 的实现 |
| `core/patch.go` | `PatchParams.Tailscale` + 规则插到订阅规则最前面 |
| `core/constant.go`、`core/action.go` | action 注册与分发 |
| `core/common.go` | `setupConfig` 后预热与清理 |
| `core/Clash.Meta/adapter/outbound/tailscale.go` | 给上层暴露实例注册表、`Status()`、`StartAsync()`、`Logout()` |
| `core/Clash.Meta/adapter/outbound/tailscale_stub.go` | `no_tailscale` 轻量构建下的同名空实现 |
| `lib/models/tailscale.dart` | Dart 侧配置模型 + 凭证模型 + 持久化 + 状态模型 |
| `lib/state.dart` | 下发 patch 参数、修补 tailnet 路由 |
| `lib/views/config/tailscale.dart` | 设置页 + 凭证管理页 |
| `lib/clash/interface.dart`、`lib/clash/core.dart`、`lib/enum/enum.dart` | action 桥接 |
| `core/tailscale_patch_test.go` | 注入逻辑的单测 |

---

## 1. 关键约束

### 1.1 Android 同时只允许一个 VpnService

代理（TUN）已经占用了它，官方 Tailscale App 没法同时在跑。

→ Tailscale 必须以 **userspace netstack**（`tsnet`）的形式编译进 core，
和 TUN 在同一个进程里共存，不能再申请 VPN 权限。

### 1.2 mihomo 自带 `tailscale` 出站

vendored 的 `core/Clash.Meta` 已包含 `adapter/outbound/tailscale.go`
（基于 `github.com/metacubex/tailscale` 的 tsnet 分支），支持三个关键钩子：

```go
SystemDialer          // 控制面 / DERP / logtail 等「非 tailnet」连接的拨号方式
SystemPacketListener  // STUN / 直连打洞用的 UDP socket 创建方式
LookupHook            // control / DERP 域名的解析方式
```

这三个钩子都由 mihomo 的 `dialer` 提供，而 `core/lib_android.go` 里给所有
mihomo socket 装了 `VpnService.protect`。钩子拿到的 socket 都被 protect 过，
所以 Tailscale 的底层流量**始终走物理网卡**。

### 1.3 底层流量一律直连，不注入 `dialer-proxy`

曾尝试把 `dialer-proxy` 塞进 tailscale 出站来实现「走代理」，结果 tsnet 起不来：

```
magicsock: Rebind IPv4 failed: failed to bind any ports (tried [0])
```

原因：`SystemPacketListener` 会调到 `proxydialer.ListenPacket`，而它只能在
已知目标地址时建立 UDP 关联；magicsock 需要的是能自由发包的通用 socket。

现在 `patchTailscale` 不写 `dialer-proxy`（配置里若残留该字段只打 warning
并忽略），socket 被 `VpnService.protect` 保护后直接走物理网卡。

### 1.4 tailnet 流量走 in-process netstack

规则里把 `100.64.0.0/10`、`fd7a:115c:a1e0::/48`、`*.ts.net` 指向 tailscale
出站，应用访问 tailnet 的流量就会经 TUN → mihomo → tsnet → WireGuard。

---

## 2. 数据流

```
                     ┌──────────────── App 进程 ────────────────┐
  其它 App 的流量 → TUN ─→ mihomo 规则 ─→ tailscale 出站 ─→ tsnet ─→ tailnet 节点
                     │                      │                     │
                     │                      │  （底层）            │
                     │                      └→ SystemDialer ──────┘
                     │                            │
                     │                      protect(fd)
                     │                            │
                     └────────────────────→ 物理网卡
```

`protect(fd)` 之后 socket 绑定物理网络，tailnet / DERP / STUN 全部真实出口。
对端设备看到的「我的地址」就是本机公网 IP。

---

## 3. 生成的配置长什么样

UI 只下发 patch 参数，真正的 YAML 由 core 生成（`core/tailscale_patch.go`）。
手工写订阅也可以直接用下面的写法，两边等价：

```yaml
proxies:
  - name: Tailscale            # 名字同时被 rules / dns 引用
    type: tailscale
    hostname: phone            # 可选，默认系统 hostname
    auth-key: tskey-auth-...   # 可选，推荐；留空则要手动打开登录链接
    control-url: ''            # 自建 Headscale 时填，例如 https://headscale.example.com
    state-dir: tailscale       # 节点状态目录（相对 app 数据目录）
    ephemeral: false
    udp: true                  # 允许该出站转发 UDP
    accept-routes: false       # 接受 subnet router 宣告的网段
    exit-node: ''              # 例如 auto:any 或具体节点 IP
    exit-node-allow-lan-access: false
    # 注意：不会写 dialer-proxy。配置里若残留，core 只打 warning 并忽略。

# 不会改动 proxy-groups。tailscale 出站是独立注入的，不加入任何组：
#   - 它不是一个「可以选来上网的代理」，放进组里容易误解
#   - 规则通过名字直接引用它（见下面的 rules），不需要组
#   - 副作用：代理页看不到它，这是设计如此

rules:
  # 注入在订阅规则最前面，避免被 GEOIP / MATCH 抢走
  - IP-CIDR,100.64.0.0/10,Tailscale,no-resolve
  - IP-CIDR6,fd7a:115c:a1e0::/48,Tailscale,no-resolve
  - DOMAIN-SUFFIX,ts.net,Tailscale
  # ...订阅原有规则
  - MATCH,Proxy

dns:
  enable: true
  nameserver-policy:
    +.ts.net: tailscale://Tailscale   # MagicDNS 交给 tsnet 自己的 resolver
```

说明：

- `tailscale://<代理名>` 是 mihomo 内置的 DNS scheme（`dns/util.go` 里的
  `case "tailscale"`），会把查询转发给对应 tailscale 出站的 `QueryDNS`，
  所以 `*.ts.net` 不需要走系统 DNS，也不会被污染。
- `no-resolve` 很重要：命中 IP 规则时不需要提前解析域名，避免 ts.net 域名
  在规则匹配阶段被别的 DNS 解析成公网 IP。
- 出站名会直接出现在注入的规则里（`IP-CIDR,...,<名字>,no-resolve`），
  所以改名字等于改规则 target，会触发一次 core 配置重建。
- 控制面域名会被自动加入 `fake-ip-filter`。自建 Headscale 时，其域名同样生效。

---

## 4. 使用方法

1. 打开 App → 设置（Config）→ **Tailscale**；
2. 打开顶部总开关；
3. 添加登录凭证，两种方式：
   - **Auth Key**：Tailscale 后台 → Settings → Keys → Generate auth key
   - **浏览器授权**：添加后点凭证条目的跳转按钮，在浏览器完成授权
4. 「自动注入 tailnet 规则」保持开启（关掉就得自己在规则里写 `100.64.0.0/10`）；
5. 「MagicDNS」保持开启，并确保 DNS 覆写是开着的，这样才能用
   `设备名.你的tailnet.ts.net` 这种名字直接访问；
6. 回到首页开启 VPN，Tailscale 页应显示「运行中」和分配到的 `100.x` 地址。

> Tailscale 出站依附于内核，而内核依附于 VPN 服务。
> **VPN 未开启时无法获取登录链接**，此时点浏览器授权会提示先开 VPN。

### 验证

```bash
# 设备侧（同一 tailnet 的另一台机器）
tailscale ping <本机 tailnet 名>
tailscale status | grep <主机名>

# 连通性
ping <对端 100.x 地址>
# MagicDNS
nslookup 设备名.你的tailnet.ts.net
```

---

## 5. 构建

默认 Android / Linux / Windows / macOS 构建**已经包含** tailscale 出站
（`core/Clash.Meta` 是 vendored 的，`go.mod` 里有 replace）。

### 5.1 工具链

| 组件 | 要求 |
| --- | --- |
| Flutter | 3.50.1+（Dart 3.14+） |
| Go | 1.24+ |
| JDK | 17 |
| Rust | 含 Android target |
| LLVM | 提供 `libclang.dll` / `libclang.so`（rquickjs 的 bindgen 需要） |
| Android SDK | platform 36 / build-tools 36 / NDK 28 / cmake 3.22+ |

需要设置的环境变量：

```bash
# 必设
export JAVA_HOME=<jdk17>                    # 不能用 JDK 25 / Android Studio 的 jbr
export ANDROID_HOME=<android-sdk>
export ANDROID_SDK_ROOT=$ANDROID_HOME
export ANDROID_NDK=$ANDROID_HOME/ndk/<version>   # setup.dart 会 assert 这个变量
export LIBCLANG_PATH=<llvm>/bin             # rquickjs 的 bindgen 需要
export TMPDIR=<可写的临时目录>               # cgo 需要可写临时目录
```

### 5.2 命令

```bash
flutter pub get

# ⚠️ 只要动过 ActionMethod 枚举 / 带注解的 model，就必须重新生成，
#    否则生成的枚举映射表查不到新值，invoke 会在 json.encode 阶段抛
#    "Converting object to an encodable object failed"
dart run build_runner build

# core（两个架构分别编，必须加 --standard）
dart setup.dart android --arch arm64 --out core --core-version alpha --standard
dart setup.dart android --arch amd64 --out core --core-version alpha --standard

# APK（必须加 --split-per-abi，理由见 5.3）
flutter build apk --release --target-platform android-arm64 --split-per-abi \
  --dart-define=APP_ENV=stable
```

### 5.3 三个非报错型的坑

都以「卡住 / 莫名失败」的形式出现。

**① 缺少 `android/local.properties`**

该文件被 `.gitignore` 忽略，而 `settings.gradle.kts` 强依赖它：

```properties
sdk.dir=<android-sdk 路径>
flutter.sdk=<flutter 路径>
```

签名也需要在这里配（见 5.4）。

**② ABI 混装**

`--target-platform android-arm64` 生成的 fat APK 里，CMake 的 `libcore.so`
会按默认 ABI 全量输出，出现 `armeabi-v7a/libcore.so` 有、`libmeta.so` 没有的
混合包 —— 在其他 ABI 的设备上会装上就崩。

**必须加 `--split-per-abi`**（或走 `setup.dart android` 的
flutter_distributor 流程，它默认就带）。

**③ Windows 未开开发者模式时无法建 symlink**

报 `Building with plugins requires symlink support.`。原因是工程里同时有
`windows/`、`linux/` 目录，`createPluginSymlinks` 会给它们建 `.plugin_symlinks`。

绕过办法（不需要管理员）：用 **junction** 预先把链接建好，
Flutter 检测到 `link.existsSync()` 为真就直接 `continue`：

```powershell
$j = Get-Content .flutter-plugins-dependencies -Raw | ConvertFrom-Json
foreach ($t in @(@{p='windows';d='windows\flutter\ephemeral\.plugin_symlinks'},
                 @{p='linux';  d='linux\flutter\ephemeral\.plugin_symlinks'})) {
  $root = Join-Path $PWD $t.d
  New-Item -ItemType Directory -Path $root -Force | Out-Null
  foreach ($pl in $j.plugins.($t.p)) {
    cmd /c mklink /J "$root\$($pl.name)" "$($pl.path.TrimEnd('\'))" | Out-Null
  }
}
```

### 5.4 签名

项目支持正式签名，四项齐全自动启用，缺任一项回退 debug 签名：

```
android/app/keystore.jks
android/local.properties
  storePassword=...
  keyAlias=...
  keyPassword=...
```

**keystore 不要提交到仓库**（`.gitignore` 已覆盖 `*.jks` 和 `local.properties`）。

换签名后已安装的用户**必须卸载重装**，否则报
`INSTALL_FAILED_UPDATE_INCOMPATIBLE`。

> Gradle 走代理要在**用户级** `~/.gradle/gradle.properties` 里写
> `systemProp.https.proxyHost/Port`（Gradle 不读 `HTTPS_PROXY` 环境变量）。

### 5.5 为什么开代理后要等一会儿 tailnet 才通

出站是懒启动的，而开代理 / 切节点会重建整个配置，于是每次都要重做一遍
control 握手 + netmap + DERP。

`core/common.go` 的 `setupConfig` 在 `hub.ApplyConfig` 之后调用了
`warmupTailscaleOutbounds()`，把这一步提前到配置生效时在后台完成，
日志里能看到 `[Tailscale](xxx) warmup: starting in background`。

### 5.6 和官方版共存

官方包的 `applicationId` 是 `com.appshub.bettbox`，本项目是
`com.appshub.bettbox.mesh`，签名也不同，**不能互相覆盖安装**。

想让两个版本并存，只改运行时身份即可（`namespace` 和 Kotlin 包路径不用动）：

```kotlin
// android/app/build.gradle.kts
applicationId = "com.appshub.bettbox.mesh"
```

```dart
// lib/common/identity.dart
static const packageId = 'com.appshub.bettbox.mesh';
```

说明：

- Android 上真正的身份由 `applicationId` 决定，`AppIdentity.packageId`
  只在 Linux 桌面拼数据目录时用到（Android 构建会被 tree-shake 掉），
  改它是为了两边一致，不影响 APK。
- `VpnService` 里对自己包名的引用用的是 `Context.packageName`（运行时取值），
  会自动跟随 `applicationId`，无需额外改。
- 工程里没有 `FileProvider` / `authorities`，不存在 authorities 冲突。

---

## 6. 单测

```bash
cd core
# 只跑 Tailscale 注入逻辑（可交叉在本机跑，不需要 Android NDK）
GOOS=windows GOARCH=amd64 CGO_ENABLED=0 go test -tags with_gvisor -run Tailscale -v .
# 全量单测（确认没有破坏原有 patch 行为）
GOOS=windows GOARCH=amd64 CGO_ENABLED=0 go test -tags with_gvisor .
# 纯编译检查（含 no_tailscale 轻量构建）
go build -tags with_gvisor .
cd Clash.Meta && go build -tags with_gvisor ./adapter/outbound/
go build -tags "with_gvisor no_tailscale" ./adapter/outbound/
```

`tailscale_patch_test.go` 覆盖：出站注入、规则顺序、DNS 策略、
直连模式不带 `dialer-proxy`、名字冲突回退、自定义 DNS 后缀。

---

## 7. 已知限制 / 排错

| 现象 | 原因 / 处理 |
| --- | --- |
| `State: NeedsLogin`，状态里有登录链接 | 没填 auth key；点链接授权后自动进入 `Running` |
| 状态显示「未配置 / 配置文件里没有 tailscale 出站」 | VPN 没启动，或配置重建被跳过。开关关掉再打开会强制重建；确认首页 VPN 是开启状态 |
| `ping 100.x` 不通但域名可以 | 没开 MagicDNS / DNS 覆写，或者规则被关掉了 |
| 开了「绕过局域网」后 tailnet 全挂 | 已由 `lib/state.dart` 的 `_withTailnetRoutes` 修补；若自己改过 `route-address`，需手动加 `100.64.0.0/10`、`fd7a:115c:a1e0::/48` |
| 官方 Tailscale App 也开着 | 两个 VpnService 冲突，必须关掉官方 App |
| Android 上 `interfaces` 相关报错 | 已在 `tailscale.go` 的 `init()` 里用 `anet` 兜底（Android 11+ 限制） |
| 订阅里已有指向 100.64/10 的规则 | 注入的规则在最前面，会优先生效；需要反向控制就把 UI 里的规则开关关掉 |
| 全局（Global）模式下 tailnet 不通 | Global 模式不经过规则匹配，注入的规则不生效；切回规则模式 |
| 登录后十几秒节点消失 | `CloseIdle()` 被实现成 `Close()`。它应是空实现，清理走 `pruneTailscaleOutbounds()` |
| Tailscale 页永远显示「未配置」，但 APK 能跑 | core 编译漏了 `--standard`，`no_tailscale` 把出站排除了。检查 `libclash/.tags/*` 应为 `with_gvisor` |

其它说明：

- **MTU**：tsnet 的 netstack MTU 是 1280，TUN 默认 9000 不影响（TUN 里是
  mihomo 自己重组 TCP）；如果遇到 tailnet 大包异常，把 TUN MTU 降到 1380 试试。
- **exit node**：填 `auto:any` 或节点 IP；Tailscale 的 exit node 只影响
  tsnet 自己的默认路由，不影响 mihomo 的分流规则。
- **subnet router**：需要 `accept-routes: true`，并且被宣告的网段还要能被
  mihomo 的规则命中（打开后这些网段会进 tsnet 的路由表，
  但 mihomo 仍然按自己的规则决定是否把流量交给 tailscale 出站）。
- **多节点**：core 支持多个 `type: tailscale` 出站并存（状态接口返回数组），
  但 UI 目前管理的是「多个凭证、同时启用一个」——`PatchParams.Tailscale`
  是单指针，一次只注入一个。

---

## 8. 后续可以做的

- 交互式登录：把 tsnet 的登录 URL 直接弹成二维码 / 一键打开（现在是从
  `Status().AuthURL` 里读）；
- 把 `TailscaleListView` 的文案搬进 `arb`，补全语言翻译；
- 在首页仪表盘加 Tailscale 状态磁贴（`Running` / 在线 peer 数）；
- Android 快捷开关：通知栏一键启停 Tailscale 出站（本质是改配置里的
  `enable` 后重建配置）。
