package main

import (
	"fmt"
	"net"
	"net/url"
	"strings"

	"github.com/metacubex/mihomo/common/orderedmap"
	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/log"
)

// PatchMesh 是 Bettbox UI 中「Mesh」组网配置集合。
//
// 采用数组结构，支持同时连接多个组网实例（如多个 ZeroTier 网络或跨协议共存）；
// 后续新增 ZeroTier / EasyTier 时直接在此结构体追加对应切片即可。
type PatchMesh struct {
	Tailscale []PatchTailscale `json:"tailscale,omitempty"`
}

// PatchTailscale 是 Bettbox UI 中「Tailscale」配置项的数据结构。
//
// Dart 侧把它放在 patch 参数的 mesh.tailscale 数组里下发，core 在合并
// 订阅配置时把它展开成：
//
//	proxies:
//	  - name: <Name>
//	    type: tailscale
//	    ...
//	    dialer-proxy: <DialerProxy>   # 空 = 直连；非空 = 底层走代理
//	rules:
//	  - IP-CIDR,100.64.0.0/10,<Name>,no-resolve
//	  - IP-CIDR6,fd7a:115c:a1e0::/48,<Name>,no-resolve
//	  - DOMAIN-SUFFIX,ts.net,<Name>
//	dns:
//	  nameserver-policy:
//	    +.ts.net: tailscale://<Name>
//
// 这样 Tailscale 与订阅里的普通节点可以同时工作：发往 tailnet 的流量
// 命中上面的规则后被吞进 in-process 的 Tailscale（userspace netstack），
// 而 Tailscale 自己的控制面 / DERP / WireGuard 底层流量则交给
// mihomo 的 dialer 处理（直连或被 dialer-proxy 送进代理）。
type PatchTailscale struct {
	Enable bool `json:"enable"`
	// Name 是注入到 proxies 里的节点名，同时被用作 rules / dns 的 target。
	Name string `json:"name"`
	// Hostname 是 Tailscale 节点在 tailnet 里显示的名字，留空则用系统 hostname。
	Hostname string `json:"hostname"`
	// AuthKey 是 control 面板生成的 auth key，推荐用它做免交互登录。
	AuthKey string `json:"auth-key"`
	// ControlURL 留空表示官方控制面（controlplane.tailscale.com），
	// 自建 headscale 时填 https://your-headscale。
	ControlURL string `json:"control-url"`
	// StateDir 是节点状态目录，默认 tailscale。
	StateDir  string `json:"state-dir"`
	Ephemeral bool   `json:"ephemeral"`
	// UDP 为 nil 时保持 mihomo 默认值。
	UDP *bool `json:"udp"`
	// AcceptRoutes 对应 --accept-routes（接受 subnet router 宣告的路由）。
	AcceptRoutes *bool  `json:"accept-routes"`
	ExitNode     string `json:"exit-node"`
	// ExitNodeAllowLANAccess 对应 --exit-node-allow-lan-access。
	ExitNodeAllowLANAccess *bool `json:"exit-node-allow-lan-access"`
	// DialerProxy 已废弃，恒为空。
	//
	// 曾经尝试用它实现「Tailscale 底层流量走代理」，但 tsnet 的 magicsock
	// 需要一个能自由发包的通用 UDP socket，而 mihomo 的
	// proxydialer.ListenPacket 只能在已知目标地址时建立 UDP 关联，
	// 接上去必然得到：
	//	magicsock: Rebind IPv4 failed: failed to bind any ports (tried [0])
	// 节点直接起不来。所以只保留直连，字段留着仅为兼容旧配置不报错。
	DialerProxy string `json:"dialer-proxy"`
	// RouteRules 为 true 时自动注入 tailnet 路由规则。
	RouteRules bool `json:"route-rules"`
	// MagicDNS 为 true 时把 ts.net 的解析交给 Tailscale 自己的 DNS。
	MagicDNS bool `json:"magic-dns"`
	// DNSSuffix 用于自定义 MagicDNS 后缀（Headscale 常见做法）。
	DNSSuffix string `json:"dns-suffix"`
}

const (
	defaultTailscaleName = "Tailscale"
	tailscaleCIDR4       = "100.64.0.0/10"
	tailscaleCIDR6       = "fd7a:115c:a1e0::/48"
	tailscaleMagicDNS    = "ts.net"
)

// tailscaleProxyName 归一化节点名，保证 rules / dns / proxies 三处一致。
func tailscaleProxyName(ts *PatchTailscale) string {
	name := strings.TrimSpace(ts.Name)
	if name == "" {
		return defaultTailscaleName
	}
	return name
}

func proxyEntryName(proxy map[string]any) string {
	if proxy == nil {
		return ""
	}
	if name, ok := proxy["name"].(string); ok {
		return name
	}
	return ""
}

func hasProxyNamed(proxies []map[string]any, name string) bool {
	for _, proxy := range proxies {
		if proxyEntryName(proxy) == name {
			return true
		}
	}
	return false
}

func hasProxyOfType(proxies []map[string]any, kind string) bool {
	for _, proxy := range proxies {
		if value, ok := proxy["type"].(string); ok && strings.EqualFold(value, kind) {
			return true
		}
	}
	return false
}

// buildTailscaleProxy 生成 mihomo 的 tailscale 出站定义。
func buildTailscaleProxy(ts *PatchTailscale, name string) map[string]any {
	entry := map[string]any{
		"name": name,
		"type": "tailscale",
	}
	if hostname := strings.TrimSpace(ts.Hostname); hostname != "" {
		entry["hostname"] = hostname
	}
	if authKey := strings.TrimSpace(ts.AuthKey); authKey != "" {
		entry["auth-key"] = authKey
	}
	if controlURL := strings.TrimSpace(ts.ControlURL); controlURL != "" {
		entry["control-url"] = controlURL
	}
	if stateDir := strings.TrimSpace(ts.StateDir); stateDir != "" {
		entry["state-dir"] = stateDir
	} else {
		entry["state-dir"] = "tailscale"
	}
	if ts.Ephemeral {
		entry["ephemeral"] = true
	}
	if ts.UDP != nil {
		entry["udp"] = *ts.UDP
	}
	if ts.AcceptRoutes != nil {
		entry["accept-routes"] = *ts.AcceptRoutes
	}
	if exitNode := strings.TrimSpace(ts.ExitNode); exitNode != "" {
		entry["exit-node"] = exitNode
	}
	if ts.ExitNodeAllowLANAccess != nil {
		entry["exit-node-allow-lan-access"] = *ts.ExitNodeAllowLANAccess
	}
	// 不再写入 dialer-proxy：见 PatchTailscale.DialerProxy 的注释，
	// 底层流量强行走代理会让 magicsock 起不来。
	if dialerProxy := strings.TrimSpace(ts.DialerProxy); dialerProxy != "" {
		log.Warnln("[Tailscale] dialer-proxy=%q is ignored: Tailscale底层流量目前只支持直连", dialerProxy)
	}
	return entry
}

// patchMesh 把 Mesh 组网配置注入到已经合并好的 RawConfig 里，
// 返回需要插到规则最前面的规则（优先级高于订阅规则）。
func patchMesh(raw *config.RawConfig, params *PatchParams) []string {
	if raw == nil || params == nil || params.Mesh == nil {
		return nil
	}
	var rules []string
	for i := range params.Mesh.Tailscale {
		rules = append(rules, patchSingleTailscale(raw, &params.Mesh.Tailscale[i])...)
	}
	return rules
}

// patchSingleTailscale 把单个 Tailscale 配置注入到已经合并好的 RawConfig 里。
func patchSingleTailscale(raw *config.RawConfig, ts *PatchTailscale) []string {
	if raw == nil || ts == nil || !ts.Enable {
		return nil
	}

	name := tailscaleProxyName(ts)
	if hasProxyNamed(raw.Proxy, name) {
		if !hasProxyOfType(raw.Proxy, "tailscale") {
			// 名字被非 tailscale 节点占用了，换一个不冲突的名字，避免污染用户配置。
			name = name + " Tailscale"
		}
		if hasProxyNamed(raw.Proxy, name) {
			// 多实例或用户配置已存在同名 tailscale 节点时追加序号，保证每个实例名称唯一。
			base := name
			for idx := 2; ; idx++ {
				candidate := fmt.Sprintf("%s %d", base, idx)
				if !hasProxyNamed(raw.Proxy, candidate) {
					name = candidate
					break
				}
			}
		}
	}
	raw.Proxy = append([]map[string]any{buildTailscaleProxy(ts, name)}, raw.Proxy...)

	var rules []string
	if ts.RouteRules {
		rules = append(rules,
			fmt.Sprintf("IP-CIDR,%s,%s,no-resolve", tailscaleCIDR4, name),
			fmt.Sprintf("IP-CIDR6,%s,%s,no-resolve", tailscaleCIDR6, name),
			fmt.Sprintf("DOMAIN-SUFFIX,%s,%s", tailscaleMagicDNS, name),
		)
		if suffix := normalizeDNSSuffix(ts.DNSSuffix); suffix != "" {
			rules = append(rules, fmt.Sprintf("DOMAIN-SUFFIX,%s,%s", suffix, name))
		}
	}

	if ts.MagicDNS {
		patchTailscaleDNS(raw, ts, name)
	}
	// 控制面域名必须绕开 FakeIP，否则 tsnet 会去连 198.18.x.x 然后一直登录失败。
	patchTailscaleFakeIPFilter(raw, ts)
	return rules
}

func normalizeDNSSuffix(suffix string) string {
	suffix = strings.TrimSpace(strings.ToLower(suffix))
	suffix = strings.TrimPrefix(suffix, ".")
	suffix = strings.TrimSuffix(suffix, ".")
	if suffix == tailscaleMagicDNS {
		return ""
	}
	return suffix
}

// patchTailscaleDNS 让 ts.net 的解析走 Tailscale 自己的 DNS（MagicDNS）。
// 只有在 profile / 覆写里开启了 DNS 时才有效：DNS 关闭时 mihomo 不参与解析，
// 此时依赖 DOMAIN-SUFFIX 规则 + 出站自带的 resolver，仍然可用。
func patchTailscaleDNS(raw *config.RawConfig, ts *PatchTailscale, name string) {
	if !raw.DNS.Enable {
		return
	}
	if raw.DNS.NameServerPolicy == nil {
		raw.DNS.NameServerPolicy = orderedmap.New[string, any]()
	}
	server := "tailscale://" + name
	suffixes := []string{tailscaleMagicDNS}
	if suffix := normalizeDNSSuffix(ts.DNSSuffix); suffix != "" {
		suffixes = append(suffixes, suffix)
	}
	for _, suffix := range suffixes {
		key := "+." + suffix
		if _, exist := raw.DNS.NameServerPolicy.Get(key); exist {
			continue
		}
		raw.DNS.NameServerPolicy.Set(key, server)
	}
}

// tailscaleControlDomains 是 tsnet 启动时必须拿到**真实 IP** 的域名。
//
// 一旦开了 FakeIP，LookupHook 查这些域名会拿到 198.18.x.x 这样的假地址，
// tsnet 于是去 dial 一个不存在的 IP，表现为：
//
//	LookupHook: finish lookup controlplane.tailscale.com, ips: [198.18.0.4]
//	SystemDialer: finish dial tcp 198.18.0.4:443, err: operation was canceled
//	register request ...: context deadline exceeded
//	status: state=NoState ips=[] peers=0/0
//
// 也就是「节点一直登录不上」，但日志里看不出是 DNS 的锅。
var tailscaleControlDomains = []string{
	"controlplane.tailscale.com",
	"login.tailscale.com",
	"derp.tailscale.com",
	"log.tailscale.io",
	"log.tailscale.com",
}

// patchTailscaleFakeIPFilter 把控制面域名加进 fake-ip-filter，
// 保证它们始终解析到真实地址。已存在的不重复添加。
func patchTailscaleFakeIPFilter(raw *config.RawConfig, ts *PatchTailscale) {
	if !raw.DNS.Enable {
		return
	}
	domains := append([]string(nil), tailscaleControlDomains...)
	// 自建 Headscale：control-url 的 host 同样不能被 FakeIP 劫持。
	if controlURL := strings.TrimSpace(ts.ControlURL); controlURL != "" {
		if host := controlURLHost(controlURL); host != "" {
			domains = append(domains, host)
		}
	}

	existing := make(map[string]bool, len(raw.DNS.FakeIPFilter))
	for _, entry := range raw.DNS.FakeIPFilter {
		existing[entry] = true
	}
	for _, domain := range domains {
		if existing[domain] {
			continue
		}
		raw.DNS.FakeIPFilter = append(raw.DNS.FakeIPFilter, domain)
		existing[domain] = true
	}
}

// controlURLHost 从 control-url 里提取 host（不带端口），失败返回空串。
func controlURLHost(controlURL string) string {
	parsed, err := url.Parse(controlURL)
	if err != nil {
		return ""
	}
	host := parsed.Hostname()
	// IP 字面量不需要进 fake-ip-filter
	if host == "" || net.ParseIP(host) != nil {
		return ""
	}
	return host
}
