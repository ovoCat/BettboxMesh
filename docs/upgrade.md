# 升级指南

如何把上游 Bettbox 的新版本合并进来，以及本项目相对上游改了什么。

---

## 1. 仓库现状

- 基线：上游 Bettbox `1.20.1+2026112501`
- remote `upstream` → `https://github.com/appshubcc/Bettbox.git`

```bash
git log --oneline                    # 本地提交历史
git log upstream/main --oneline -5   # 上游最新提交
git diff upstream/main HEAD --stat   # 看自己改了什么
```

> 构建产物（`build/`、`libclash/`、`android/core/.cxx/`、`core/core` 等）
> 已在 `.gitignore` 中排除，不会进仓库。

---

## 2. 升级流程

### 2.1 拉取上游

```bash
git fetch upstream main
git log --oneline HEAD..upstream/main    # 上游新增了什么
git diff HEAD upstream/main --stat       # 上游改了哪些文件
```

### 2.2 先看上游有没有原生支持 Tailscale

这一步能省掉大量工作：

```bash
git log upstream/main --oneline | grep -i tailscale
git diff HEAD upstream/main --stat | grep -i tailscale
```

- **有** → 说明上游自己做了，优先采用上游实现，只保留我们的 UI 增强
  （`lib/views/config/tailscale.dart`、`lib/models/tailscale.dart`）。
- **没有** → 按 2.3 处理。

### 2.3 不能 git merge，必须重打补丁

本仓库与 `upstream/main` **没有共同祖先**，`git merge upstream/main` 只会得到：

```
fatal: refusing to merge unrelated histories
```

加上 `--allow-unrelated-histories` 后，Git 会把**每个文件**都判成
`CONFLICT (add/add)`（实测 2500+ 文件全部冲突），无法逐个人工处理。

**正确做法：基于上游新版本重新打补丁。**

```bash
# 1) 浅克隆上游新版本到独立目录（保持纯净基线）
git clone --depth 1 https://github.com/appshubcc/Bettbox.git ../upstream-new

# 2) 把纯新增文件直接复制过去（上游不会有同名文件，零冲突）
#    见第 2.4 节的分类表

# 3) vendored 补丁：先确认上游没改过，再覆盖
git diff <基线提交> upstream/main --name-only -- core/Clash.Meta/adapter/outbound/
#    无输出 = 安全覆盖

# 4) 接线点：读上游新结构，逐个插入（本仓库改动只有 ~30 个文件，量可控）

# 5) 编译验证（见第 4 节），再复制回本仓库

# 6) 把新源码同步回本仓库
rsync -a --exclude .git --exclude build --exclude .dart_tool \
      --exclude libclash ../upstream-new/ .
git add -A && git commit
```

> **为什么要另开目录**：某些受限环境（沙箱、只读挂载）下 git / go 子进程
> 可能无法写入当前目录（`go mod tidy` 报 `Access is denied`）。把源码放到
> 可写目录编译，成功后再同步回来，能绕开这类问题。

### 2.4 冲突处理优先级

按下表判断，**从上到下处理**：

| 文件 | 类型 | 冲突策略 |
| --- | --- | --- |
| `core/tailscale_patch.go`<br>`core/tailscale_status.go`<br>`core/tailscale_patch_test.go`<br>`lib/models/tailscale.dart`<br>`lib/views/config/tailscale.dart`<br>`docs/tailscale.md` | **纯新增** | 上游不会有同名文件，理论上零冲突。若真冲突说明上游也做了 Tailscale，停下来重新设计 |
| `core/Clash.Meta/adapter/outbound/tailscale.go`<br>`tailscale_stub.go` | **vendored 补丁** | 保留我们的补丁，把上游新逻辑合进来。改动集中在文件尾部且是追加 |
| `core/patch.go` `core/constant.go` `core/action.go` `core/common.go`<br>`lib/enum/enum.dart` `lib/clash/*.dart` `lib/state.dart`<br>`lib/controller.dart` `lib/common/navigation.dart` `lib/views/config/config.dart` | **接线点** | 通常自动合并。确认 Method 常量、枚举值、NavigationItem 还在原位 |
| `lib/common/constant.dart` `lib/common/print.dart`<br>`lib/manager/clash_manager.dart` `lib/views/logs.dart` `lib/main.dart` | **可选增强** | **可以直接接受上游版本**（见第 3 节），我们的功能只是暂时关闭 |
| `lib/models/generated/*.g.dart` | **生成产物** | 不要手改，合并后重跑 `dart run build_runner build` |

### 2.5 README 类文件属于定制内容，不能直接接受上游

**1.20.1 升级时踩过**：`README.md` 和 `readme/` 目录被当作纯上游文件覆盖，
导致所有定制内容丢失：

| 丢失项 | 后果 |
| --- | --- |
| 标题 `BettboxMesh` | 变回 `Bettbox` |
| 「相对上游的差异」章节 | 整个消失 |
| 「文档索引」章节 | 整个消失 |
| 项目热度指向 | 从 `ovoCat/BettboxMesh` 变回上游 |
| 截图 `tail_cn.png` | 换成上游的 `home.jpg` |
| 多语言版本 | 已删的 fa/ja/ko/ru 被恢复 |

**规律**：这类「文档型资产」不会引起编译错误，所以最容易被忽略。
判断标准是 —— **凡是本项目的定制内容，都不属于「可直接接受上游」的范畴**。

升级时必须逐项确认：

```
README.md                      定制（标题、差异说明、文档索引、项目热度）
readme/README_en.md            定制
readme/README_*.md             本项目只保留 en + zh，其余应删除
.github/ISSUE_TEMPLATE/*.yml   定制（链接指向本仓库）
lib/views/about.dart           定制（双气泡墙）
android/app/build.gradle.kts   定制（applicationId）
res/values*/strings.xml        定制（显示名）
```

**恢复方法**（历史里一定有提交前的版本）：

```bash
# 找到保留定制内容的提交
git log --oneline -- README.md

# 从该提交恢复
git show <commit>:README.md > README.md
git show <commit>:readme/README_en.md > readme/README_en.md
```

**升级后必查**：

```bash
# 关键字应全部命中
Select-String -Path README.md -Pattern "BettboxMesh|Tailscale"
# readme/ 应只剩两个文件
Get-ChildItem readme
```

---

## 3. 可选的调试增强（`--dart-define`）

相对于上游，本项目把「日志相关」的侵入性改动做成了编译开关，**默认关闭**，
行为与上游完全一致。

| 开关 | 默认 | 作用 |
| --- | --- | --- |
| `PERSISTENT_LOG` | `false` | 常驻开启内核日志流，`adb logcat` 随时能看到 |
| `PERSIST_LOG_FILE` | `false` | 额外把日志写入 `files/debug.log`（需同时开 `PERSISTENT_LOG`） |

```bash
# 日常使用 / 与上游一致
flutter build apk --release --target-platform android-arm64 --split-per-abi

# 排查问题时
flutter build apk --release --target-platform android-arm64 --split-per-abi \
  --dart-define=PERSISTENT_LOG=true --dart-define=PERSIST_LOG_FILE=true
```

**好处**：升级时这 5 个文件可以直接接受上游版本，补丁不会成为强依赖。

---

## 4. 升级后必做的验证

```bash
# 0) 工具链：需要 Flutter >= 3.50.1（pubspec 约束 Dart >= 3.13.0）
#    版本不够会在 pub get 直接失败：
#    "Because bett_box requires SDK version >=3.14.0 <4.0.0"
dart --version

# 1) 【必须】重新生成代码
#    只要动过 ActionMethod / PageLabel 等被 json_serializable 覆盖的枚举，
#    这一步不做就会在【运行期】炸，且报错完全看不出根因：
#      Converting object to an encodable object failed: Instance of '_Action'
#    实测踩过两次（1.19.8 baseline 和 1.19.9 rebase 各一次）。
#    验证：lib/models/generated/core.g.dart 的 _$ActionMethodEnumMap 里
#    应该能找到 getTailscaleStatus / startTailscale。
dart run build_runner build --delete-conflicting-outputs

# 2) 全项目静态检查
dart analyze lib

# 3) Tailscale 注入逻辑单测（9 个用例）
cd core
GOOS=windows GOARCH=amd64 CGO_ENABLED=0 \
  go test -tags with_gvisor -run "Tailscale|ControlURLHost" -v .

# 4) 两种构建标签都要能编
go build -tags with_gvisor .
go build -tags "with_gvisor no_tailscale" ./Clash.Meta/adapter/outbound/

# 5) 重新编 core 与 APK
cd ..
dart setup.dart android --arch arm64 --out core --standard
flutter build apk --release --target-platform android-arm64 --split-per-abi \
  --dart-define=APP_ENV=stable
```

---

## 5. 相对上游的改动清单

```
 core/Clash.Meta/adapter/outbound/tailscale.go      | +210  (vendored 补丁)
 core/Clash.Meta/adapter/outbound/tailscale_stub.go |  +50  (vendored 补丁)
 core/tailscale_patch.go                            |  292  (纯新增)
 core/tailscale_patch_test.go                       |  265  (纯新增)
 core/tailscale_status.go                           |  250  (纯新增)
 lib/models/tailscale.dart                          |  600  (纯新增)
 lib/views/config/tailscale.dart                    |  770  (纯新增)
 docs/tailscale.md docs/upgrade.md dev.md           |       (纯新增)
 core/patch.go core/constant.go core/action.go core/common.go | 接线点
 lib/enum/enum.dart lib/clash/{interface,core}.dart lib/state.dart | 接线点
 lib/controller.dart lib/common/navigation.dart lib/views/config/config.dart | 接线点
 lib/models/models.dart lib/common/{constant,print,identity}.dart | 接线点/可选
 lib/manager/clash_manager.dart lib/views/logs.dart lib/main.dart | 可选增强
 android/app/build.gradle.kts AndroidManifest.xml(×2) strings.xml(×4) | 品牌
 android/.../services/{BaseServiceInterface,BettboxVpnService}.kt | 品牌
```

共约 34 个文件。

### 改动归类

| 类别 | 文件 | 升级风险 |
| --- | --- | --- |
| 纯新增（Tailscale 实现） | 6 个文件，约 2200 行 | 无 |
| vendored mihomo 补丁 | `tailscale.go`、`tailscale_stub.go` | 中 |
| 接线点（1~3 行） | patch/constant/action/common/enum/clash/state/controller/navigation | 低 |
| 可选增强（有开关） | constant/print/clash_manager/logs/main | **零**（可直接接受上游） |
| 品牌定制 | `identity.dart`、`build.gradle.kts`、`AndroidManifest.xml`、`strings.xml`×4、`debug/AndroidManifest.xml` | 低 |

---

## 6. 已知限制

- **不提供「走代理」模式**。tsnet 的 magicsock 需要一个能自由发包的通用 UDP
  socket，而 mihomo 的 `proxydialer.ListenPacket` 只能在已知目标地址时建立
  UDP 关联，接上去必然报
  `magicsock: Rebind IPv4 failed: failed to bind any ports (tried [0])`。
  控制面、DERP、WireGuard 全部直连物理网卡（socket 被 `VpnService.protect`）。
- **x86_64 的 `libcore.so` 需要清 CMake 缓存**。首次为模拟器编 x86_64 包时，
  若 `android/core/.cxx` 有旧缓存，会编出缺少 JNI 符号的空壳库，点开关即崩
  （`UnsatisfiedLinkError: startTun`）。删除 `.cxx` 和 `build/core` 后重编即可。
- **订阅里的 `log-level: silent`** 会覆盖 App 设置，导致内核完全静音。
  需要手动到「内核配置 → 常规 → 日志等级」改成 Debug。
- **签名**：需自备 keystore（见 `docs/tailscale.md` 5.4）。缺省时回退 debug
  签名，此时能装能跑，但不能用于正式分发，且换签名后用户必须卸载重装。

---

## 7. 七个必须知道的陷阱

这些都已踩过，写下来避免以后（含上游合并时）重犯。

### 7.1 编译 core 必须加 `--standard`（1.19.9 起）

上游把 `setup.dart` 的构建变体参数从 `lite` 改名为 `standard`，并**翻转了
默认值**：

```dart
static String getTags(BuildItem buildItem, {bool standard = false}) {
  if (!standard) {
    return 'no_easytier,no_tailscale,no_zerotier,no_fake_tcp,with_low_memory';
  }
  ...
}
```

不加 `--standard` 时 Tailscale 会被 `no_tailscale` 整个排除，`libmeta.so`
从 63 MB 掉到 39 MB，`magicsock` / `derp` 符号消失。**但 APK 照常能装能跑**，
只是 Tailscale 页永远显示「未配置」，极易误判成代码 bug。

检查方法（编完 core 立刻看）：

```bash
cat libclash/.tags/android-arm64-v8a
# 正确: with_gvisor        （或 with_gvisor,with_low_memory，v7a）
# 错误: no_easytier,no_tailscale,...
```

APK 侧也能验：`libmeta.so` 里 `magicsock` 出现上千次、`tsnet` 约 154 次才算对。

### 7.2 配置变更必须走 `setupConfig`，不能走 `updateConfig`

两条配置路径的作用范围完全不同：

| 路径 | 能力 |
| --- | --- |
| `updateClashConfig()` → core `updateConfig()` | **只**改运行时字段：端口、模式、日志级别、IPv6、外部控制器… |
| `restartCore()` → core `setupConfig()` | 重新解析 rawConfig、重建 tunnel、注入 proxies/rules/dns |

Tailscale 出站、tailnet 规则、MagicDNS、fake-ip-filter **全部只在
`setupConfig` 里生效**。最初 Tailscale 的开关错走了 `updateConfig`，导致：

- 首次填 Key 开启 → 无效，必须重启 App（启动才走 setupConfig）
- 关闭开关 → 旧出站没移除，Tailscale 继续工作（开关形同摆设）

**同时**，`_checkIfNeedReapply()` 只比对 profile 文件时间，感知不到
Tailscale 配置变化，所以「VPN 没启动时改配置、之后点启动」会走快路径跳过
setupConfig。为此在 controller 里加了 Tailscale 配置版本号
（`_tailscaleConfigRevision` / `_appliedTailscaleRevision`）作为额外的重建
触发条件。

**新增任何「注入型」配置时，务必确认它走的是 setupConfig。**

### 7.3 `IdleCloser` 的语义不是「删除这个节点」

`outbound.IdleCloser` 只有一个 `CloseIdle()` 方法，名字极容易误解。它的真实
语义是「**连接空闲后释放底层传输资源**」，mihomo 会在**健康检查之后**以及
配置重建时调用它。

tsnet 是常驻的用户态网络栈——netmap 长连接、DERP 连接本身就不是「空转」。
曾把 `CloseIdle()` 实现成 `Close()`，结果节点登录成功 18 秒后就被健康检查
触发关闭，状态永久变成「配置文件里没有 tailscale 出站」。

正确做法：

- `CloseIdle()` 保持**空实现**
- 「用户把节点删了」的清理放在 core 的 `setupConfig` 之后：
  `pruneTailscaleOutbounds()` 遍历已注册实例，凡是名字不在
  `tunnel.Proxies()` 里的（即新配置中已不存在）才 `Close()`。
  这里能拿到 apply 之后的最新代理表，判断依据最准确。

### 7.4 「添加凭证」不等于「已经注册」

UI 上添加凭证只是把它写进本地 prefs（`tailscale_profiles`）。真正的
control plane 注册发生在：

```
VPN 开启 → 内核 setupConfig → 创建 tailscale 出站 → tsnet 启动
  → 用 auth-key 注册 / 或生成 auth-url 等待授权
```

所以：

- **VPN 未开启时添加的凭证处于「待用」状态**，不会向 Tailscale 注册
- 此时点「浏览器授权」拿不到 login url，应提示用户先开 VPN
- 首次安装后**必须检查 `TailscaleConfigManager.ensureLoaded()` 被调用过**。
  它曾存在但无人调用，导致重启后凭证「消失」（实际只是没被读取）

这个坑的教训：**配置类功能必须验证「重启后还在不在」**。
只在「添加即用」的路径上测试，会漏掉整类问题。

### 7.5 冷启动路径必须加载配置

1.20.1 修过的一个 BUG：**从控制中心快捷开关冷启动时 Tailscale 不运行**。

根因是 `TailscaleConfigManager.ensureLoaded()` 只在打开 Tailscale 设置页时调用。
后台服务入口 `_service()` 走的是另一条路径：

```
_service() → globalState.init() → getSetupParams() → getClashConfig()
  → tailscaleConfig.toPatchJson()
```

此时 manager 还是内存默认值（`enable = false`），内核收到 `enable: false`，
VPN 正常启动但没有注入 Tailscale 出站，Tailscale 页显示「未配置」。

**修复**：在 `globalState.init()` 的并行初始化列表和 `buildSetupParams()`
开头都调用 `ensureLoaded()` 兜底。

**推广到其他功能**：任何「配置持久化 + 分多条启动路径」的功能，都要确认
**每条路径都加载了配置**，而不是只在 UI 页面里加载。

### 7.6 Rust 组件编译失败时构建不报错

`plugins/code_forge` 通过 cargokit 编译 Rust。失败时 **`flutter build apk`
退出码仍是 0**，但 APK 缺少 `libcode_forge.so`。

常见原因：`LIBCLANG_PATH` 未设置（rquickjs 的 bindgen 依赖它）。

**每次出包后必查**：

```bash
jar tf <apk> | grep libcode_forge
```

缺这个库的包比正常包小约 1.25 MB。危险之处在于**没有任何报错中断构建**。

> 升级上游时 `.gitignore` 也可能被覆盖，导致 `buildenv.ps1`、`core/core`
> 这类本地文件被带进提交。合并后务必 `git status` 检查一遍。

### 7.7 Flutter 的 assets 声明不递归子目录

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

