package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/metacubex/mihomo/adapter/outbound"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel"
)

const tailscaleStatusTimeout = 8 * time.Second

type tailscaleStatusPayload struct {
	Nodes []*outbound.TailscaleStatus `json:"nodes"`
}

// tailscaleRequestName 解析 Dart 侧下发的 {"name": "..."} ，
// 也兼容直接下发字符串 / 空数据。
func tailscaleRequestName(data interface{}) string {
	switch value := data.(type) {
	case nil:
		return ""
	case string:
		trimmed := value
		if trimmed == "" {
			return ""
		}
		var request struct {
			Name string `json:"name"`
		}
		if err := json.Unmarshal([]byte(trimmed), &request); err == nil && request.Name != "" {
			return request.Name
		}
		return trimmed
	case map[string]interface{}:
		if name, ok := value["name"].(string); ok {
			return name
		}
	}
	return ""
}

// handleGetTailscaleStatus 返回所有 tailscale 出站的状态快照，
// 不做首次阻塞启动（未启动的节点返回 idle），避免 UI 卡住。
func handleGetTailscaleStatus(data interface{}) string {
	name := tailscaleRequestName(data)
	instances := outbound.TailscaleInstances()
	nodes := make([]*outbound.TailscaleStatus, 0, len(instances))
	if len(instances) == 0 {
		nodes = append(nodes, &outbound.TailscaleStatus{
			Name:  defaultTailscaleName,
			State: "absent",
			Error: "配置文件里没有 tailscale 出站",
		})
		payload, _ := json.Marshal(tailscaleStatusPayload{Nodes: nodes})
		return string(payload)
	}

	ctx, cancel := context.WithTimeout(context.Background(), tailscaleStatusTimeout)
	defer cancel()
	for _, ts := range instances {
		if name != "" && ts.Name() != name {
			continue
		}
		status, err := ts.Status(ctx)
		if status == nil {
			status = &outbound.TailscaleStatus{Name: ts.Name(), State: "error"}
		}
		if err != nil {
			status.State = "error"
			status.Error = err.Error()
			log.Warnln("[Tailscale](%s) status error: %v", ts.Name(), err)
		} else {
			log.Infoln("[Tailscale](%s) status: state=%s ips=%v peers=%d/%d dialer-proxy=%q",
				ts.Name(), status.State, status.IPs, status.OnlinePeers, status.PeerCount, status.DialerProxy)
		}
		nodes = append(nodes, status)
	}
	payload, err := json.Marshal(tailscaleStatusPayload{Nodes: nodes})
	if err != nil {
		return ""
	}
	return string(payload)
}

// warmupTailscaleOutbounds 在配置生效后预热 tailscale 出站。
//
// 出站默认是懒启动的（第一次 Dial 才 Start），而开代理/切节点会重建
// 整个配置，于是每次都要重新做 control 握手 + netmap + DERP，用户会
// 感觉「开了总代理要等一会儿 tailnet 才通」。这里在配置 apply 完就
// 后台把它们拉起来，把这段等待挪到用户看不到的地方。
//
// 只预热当前 tunnel 里真实存在的出站，避免把 validateConfig 阶段
// 创建又没被使用的实例也拉起来（同一个 state-dir 起两个节点会打架）。
func warmupTailscaleOutbounds() {
	instances := outbound.TailscaleInstances()
	if len(instances) == 0 {
		return
	}
	proxies := tunnel.Proxies()
	for _, ts := range instances {
		if _, ok := proxies[ts.Name()]; !ok {
			continue
		}
		log.Infoln("[Tailscale](%s) warmup: starting in background", ts.Name())
		ts.StartAsync()
	}
}

// pruneTailscaleOutbounds 关闭所有「已经不在当前配置里」的 tailscale 实例。
//
// 为什么要单独做：mihomo 在配置重建时只会对实现了 IdleCloser 的适配器调
// CloseIdle，而 IdleCloser 的语义是「连接空闲释放资源」，**不能**用来表达
// 「这个节点被删了」——把 CloseIdle 写成 Close 会导致刚登录成功的节点十几秒
// 后被杀（健康检查后就会触发），状态变成「配置文件里没有 tailscale 出站」。
//
// 所以关闭逻辑放在这里：setupConfig 应用完新配置后，凡是不在 tunnel.Proxies()
// 里的 tailscale 实例，都是被用户关掉开关或从配置移除的，直接 Close 掉。
// 这样 UI 开关才真正生效，也不会误杀仍在配置中的实例。
func pruneTailscaleOutbounds() {
	instances := outbound.TailscaleInstances()
	if len(instances) == 0 {
		return
	}
	proxies := tunnel.Proxies()
	for _, ts := range instances {
		if _, ok := proxies[ts.Name()]; ok {
			continue
		}
		log.Infoln("[Tailscale](%s) closed (removed from config / switch off)", ts.Name())
		if err := ts.Close(); err != nil {
			log.Warnln("[Tailscale](%s) close failed: %v", ts.Name(), err)
		}
	}
}

// handleLogoutTailscale 让节点退出 tailnet 并清空本地登录态。
//
// 触发场景：用户把 auth-key 从配置里删掉/改掉时，UI 会调这个方法。
// 因为登录态存在 state-dir 里，光删 key 不会让已登录的节点退出，
// 必须显式登出并清目录，下次启动才会重新走 NeedsLogin 给出新的授权链接。
// tailscaleLogoutTarget 从请求里取出节点名和 state-dir。
//
// state-dir 必须由 UI 传进来：实例不存在时它是唯一能定位登录态的线索，
// core 侧无法凭空猜出配置里写的相对路径（C.Path.Resolve 依赖运行目录）。
func tailscaleLogoutTarget(data interface{}) (name string, stateDir string) {
	switch value := data.(type) {
	case string:
		if value == "" {
			return "", ""
		}
		var req struct {
			Name     string `json:"name"`
			StateDir string `json:"state-dir"`
		}
		if err := json.Unmarshal([]byte(value), &req); err == nil {
			return req.Name, req.StateDir
		}
		return value, ""
	case map[string]interface{}:
		n, _ := value["name"].(string)
		d, _ := value["state-dir"].(string)
		return n, d
	}
	return "", ""
}

func handleLogoutTailscale(data interface{}) string {
	name, stateDir := tailscaleLogoutTarget(data)
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	var errs []string

	// 路径一：实例还活着（VPN 正在跑），走正常登出，能顺带解绑 control plane。
	if name != "" {
		if ts := outbound.GetTailscaleInstance(name); ts != nil {
			if err := ts.Logout(ctx); err != nil {
				errs = append(errs, err.Error())
			} else {
				return strings.Join(errs, "; ")
			}
		}
	}

	// 路径二：实例不存在（VPN 没跑 / 配置已重建）。
	//
	// 这是「清空 auth-key」最常见的场景：出站早就不在 tunnel 里了，
	// 所以拿不到实例，也就走不了 lc.Logout。但 state-dir 里的 node key
	// 仍然有效，下次启动 tsnet 会直接恢复登录——正是用户报的「key 删了
	// 却还是登录状态」。所以这里必须能脱离实例直接清目录。
	//
	// 代价：control plane 侧的旧设备记录没法用 Logout 解绑，会在 tailnet
	// 里留一条离线记录，需要用户在 Tailscale 后台手动删。相比「删了 key
	// 退不出去」，这个取舍是可接受的（日志里也会提示）。
	if stateDir != "" {
		// 配置里写的是相对路径（默认 "tailscale"），必须按 core 的规则解析。
		stateDir = C.Path.Resolve(stateDir)
		// 安全校验：RemoveAll 会递归删除，绝不能让配置里的任意路径直接传进来。
		// 与 NewTailscale 的处理保持一致（它也在 Resolve 之后调 IsSafePath）。
		// 没有这一步的话，一份被篡改的配置（或未来的 UI bug）传个绝对路径
		// 就能删掉应用数据目录以外的东西。
		if !C.Path.IsSafePath(stateDir) {
			return fmt.Sprintf("refuse to clear unsafe path %q", stateDir)
		}
		if err := os.RemoveAll(stateDir); err != nil {
			errs = append(errs, fmt.Sprintf("clear state dir %s: %v", stateDir, err))
		} else {
			log.Infoln("[APP] tailscale state dir cleared without live instance: %s", stateDir)
		}
	} else {
		errs = append(errs, "no tailscale instance and no state-dir provided")
	}

	if len(errs) > 0 {
		return strings.Join(errs, "; ")
	}
	return ""
}

// handleStartTailscale 主动拉起（连接）Tailscale 节点：
// 配置加载时出站是懒启动的，UI 点「连接」后立即在后台启动，
// 这样状态面板可以马上看到 NeedsLogin / Running 等状态。
func handleStartTailscale(data interface{}) string {
	name := tailscaleRequestName(data)
	if name != "" {
		ts := outbound.GetTailscaleInstance(name)
		if ts == nil {
			return fmt.Sprintf("tailscale proxy %q not found", name)
		}
		ts.StartAsync()
		return ""
	}
	instances := outbound.TailscaleInstances()
	if len(instances) == 0 {
		return "no tailscale proxy in current config"
	}
	for _, ts := range instances {
		ts.StartAsync()
	}
	return ""
}
