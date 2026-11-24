//go:build with_gvisor && !no_tailscale

package outbound

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/metacubex/mihomo/component/ca"
	"github.com/metacubex/mihomo/component/dialer"
	"github.com/metacubex/mihomo/component/iface/anet"
	"github.com/metacubex/mihomo/component/resolver"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/dns"
	"github.com/metacubex/mihomo/log"

	ts "github.com/metacubex/tailscale"
	"github.com/metacubex/tailscale/envknob"
	"github.com/metacubex/tailscale/hostinfo"
	"github.com/metacubex/tailscale/ipn"
	"github.com/metacubex/tailscale/net/netmon"
	"github.com/metacubex/tailscale/tailcfg"
	"github.com/metacubex/tailscale/tsnet"
	D "github.com/miekg/dns"
	"github.com/samber/lo"
)

type Tailscale struct {
	*Base
	server      *tsnet.Server
	dnsResolver *dns.Resolver
	option      TailscaleOption
	ctx         context.Context
	cancel      context.CancelFunc
	startOnce   sync.Once
	startErr    error

	backendInitOnce sync.Once
	backendInitCh   chan struct{}
	backendInitErr  error

	serverStarted bool
	running       atomic.Bool
	lastStartErr  atomic.Value // string
	closeOnce     sync.Once
	closeErr      error

	unregisterDNSResolver func()
}

type TailscaleOption struct {
	BasicOption
	Name       string `proxy:"name"`
	Hostname   string `proxy:"hostname,omitempty"`
	AuthKey    string `proxy:"auth-key,omitempty"`
	ControlURL string `proxy:"control-url,omitempty"`
	StateDir   string `proxy:"state-dir,omitempty"`
	Ephemeral  bool   `proxy:"ephemeral,omitempty"`
	UDP        bool   `proxy:"udp,omitempty"`

	AcceptRoutes           *bool  `proxy:"accept-routes,omitempty"`
	ExitNode               string `proxy:"exit-node,omitempty"`
	ExitNodeAllowLANAccess *bool  `proxy:"exit-node-allow-lan-access,omitempty"`
}

func init() {
	hostinfo.RegisterHostinfoNewHook(func(hi *tailcfg.Hostinfo) {
		versionDotTxt := strings.TrimSpace(ts.VersionDotTxt)
		hi.IPNVersion = fmt.Sprintf("%s-%s-%s", versionDotTxt, C.MihomoName, C.Version)
	})
	envknob.SetNoLogsNoSupport()
	if runtime.GOOS == "android" { // Android SDK 30 no longer permits Go's net.Interfaces to work (Issue 2293)
		netmon.RegisterInterfaceGetter(func() (nif []netmon.Interface, err error) {
			log.Debugln("[Tailscale] InterfaceGetter: start, IsForceAnet: %v", anet.IsForceAnet())
			ifaces, err := anet.Interfaces()
			if err != nil {
				log.Warnln("[Tailscale] anet.Interfaces failed: %v", err)
				return nil, err
			}
			for _, iff := range ifaces {
				addrs, err := anet.InterfaceAddrsByInterface(&iff)
				if err != nil {
					log.Warnln("[Tailscale] anet.InterfaceAddrsByInterface(%v) failed: %v", iff.Name, err)
					continue
				}
				nif = append(nif, netmon.Interface{
					Interface: &net.Interface{
						Index:        iff.Index,
						MTU:          iff.MTU,
						Name:         iff.Name,
						HardwareAddr: iff.HardwareAddr,
						Flags:        iff.Flags,
					},
					AltAddrs: addrs,
				})
			}

			log.Debugln("[Tailscale] InterfaceGetter: %v", lo.Map(nif, func(item netmon.Interface, index int) string {
				var addrs any
				addrs, err := item.Addrs()
				if err != nil {
					addrs = err
				}
				return fmt.Sprintf("{Name: %s, Addrs: %v, IsUp: %v, IsLoopback: %v}", item.Name, addrs, item.IsUp(), item.IsLoopback())
			}))
			return
		})
	}
}

func NewTailscale(option TailscaleOption) (*Tailscale, error) {
	if _, err := buildTailscaleMaskedPrefs(option); err != nil {
		return nil, err
	}
	if option.StateDir == "" {
		option.StateDir = "tailscale"
	}
	option.StateDir = C.Path.Resolve(option.StateDir)
	if !C.Path.IsSafePath(option.StateDir) {
		return nil, C.Path.ErrNotSafePath(option.StateDir)
	}

	addr := option.ControlURL
	if addr == "" {
		addr = "tailscale"
	}
	ctx, cancel := context.WithCancel(context.Background())
	outbound := &Tailscale{
		Base: NewBase(BaseOption{
			Name:         option.Name,
			Addr:         addr,
			Type:         C.Tailscale,
			ProviderName: option.ProviderName,
			UDP:          option.UDP,
			Interface:    option.Interface,
			RoutingMark:  option.RoutingMark,
			Prefer:       option.IPVersion,
		}),
		option:        option,
		ctx:           ctx,
		cancel:        cancel,
		backendInitCh: make(chan struct{}),
	}
	outbound.dialer = option.NewDialer(outbound.DialOptions())
	outbound.server = &tsnet.Server{
		Dir:        option.StateDir,
		Hostname:   option.Hostname,
		AuthKey:    option.AuthKey,
		ControlURL: option.ControlURL,
		Ephemeral:  option.Ephemeral,
		SystemDialer: func(ctx context.Context, network, address string) (net.Conn, error) {
			log.Debugln("[Tailscale](%s) SystemDialer: start dial %s %s", option.Name, network, address)
			conn, err := outbound.dialer.DialContext(ctx, network, address)
			log.Debugln("[Tailscale](%s) SystemDialer: finish dial %s %s, err: %v", option.Name, network, address, err)
			return conn, err
		},
		SystemPacketListener: func(ctx context.Context, network, address string) (net.PacketConn, error) {
			log.Debugln("[Tailscale](%s) SystemPacketListener: start listen %s %s", option.Name, network, address)
			pc, err := outbound.dialer.ListenPacket(ctx, network, address, netip.AddrPort{})
			log.Debugln("[Tailscale](%s) SystemPacketListener: finish listen %s %s, err: %v", option.Name, network, address, err)
			return pc, err
		},
		ExtraRootCAs: ca.GetCertPool(),
		LookupHook: func(ctx context.Context, host string) ([]netip.Addr, error) {
			log.Debugln("[Tailscale](%s) LookupHook: start lookup %s", option.Name, host)
			ips, err := resolver.LookupIPWithResolver(ctx, host, resolver.ProxyServerHostResolver)
			if real := filterFakeIPs(host, ips); len(real) > 0 {
				ips = real
			} else if len(ips) > 0 {
				// 只有 FakeIP 没有真实地址：tsnet 拿假 IP 一定连不上，
				// 与其让它超时重试 10 秒，不如用系统解析器再查一次。
				log.Warnln("[Tailscale](%s) LookupHook: %s only resolved to fake ip %v, falling back to system resolver", option.Name, host, ips)
				if sysIPs, sysErr := resolver.SystemResolver.LookupIP(ctx, host); sysErr == nil && len(sysIPs) > 0 {
					ips, err = sysIPs, nil
				}
			}
			log.Debugln("[Tailscale](%s) LookupHook: finish lookup %s, ips: %v, err: %v", option.Name, host, ips, err)
			return ips, err
		},
		UserLogf: func(format string, args ...any) {
			log.Infoln("[Tailscale](%s) %s", option.Name, fmt.Sprintf(format, args...))
		},
		Logf: func(format string, args ...any) {
			log.Debugln("[Tailscale](%s) %s", option.Name, fmt.Sprintf(format, args...))
		},
	}
	dnsTransport := tailscaleDNSTransport{tailscale: outbound}
	outbound.dnsResolver = dns.NewResolverFromClient(dnsTransport)
	outbound.unregisterDNSResolver = dns.RegisterTailscaleDnsClient(option.Name, dnsTransport)
	registerTailscaleInstance(outbound)
	return outbound, nil
}

func (t *Tailscale) start() error {
	t.startOnce.Do(func() {
		if err := t.server.Start(); err != nil {
			t.startErr = err
			t.lastStartErr.Store(err.Error())
			t.setBackendInitialized(err)
			return
		}
		t.serverStarted = true
		t.running.Store(true)
		ctx, cancel := context.WithTimeout(t.ctx, 30*time.Second)
		defer cancel()
		if err := t.applyPrefs(ctx); err != nil {
			t.startErr = err
			t.lastStartErr.Store(err.Error())
			t.setBackendInitialized(err)
			return
		}
		go t.watchBackendState()
	})
	return t.startErr
}

func (t *Tailscale) ensureStarted(ctx context.Context) error {
	if err := t.start(); err != nil {
		return err
	}
	return t.waitBackendInitialized(ctx)
}

func (t *Tailscale) watchBackendState() {
	lc, err := t.server.LocalClient()
	if err != nil {
		t.setBackendInitialized(err)
		return
	}
	watcher, err := lc.WatchIPNBus(t.ctx, ipn.NotifyInitialState)
	if err != nil {
		t.setBackendInitialized(err)
		return
	}
	defer watcher.Close()

	backendInitialized := false
	exitNodeNeedsStatus := tailscaleExitNodeNeedsStatus(t.option)
	for {
		n, err := watcher.Next()
		if err != nil {
			t.setBackendInitialized(err)
			return
		}
		if n.State == nil {
			continue
		}

		if *n.State != ipn.NoState && !backendInitialized {
			t.setBackendInitialized(nil)
			backendInitialized = true
			if !exitNodeNeedsStatus {
				return
			}
		}
		if exitNodeNeedsStatus && *n.State == ipn.Running {
			if err := t.applyExitNodePrefs(t.ctx); err != nil {
				log.Warnln("[Tailscale](%s) set exit node failed: %v", t.Name(), err)
			}
			return
		}
	}
}

func (t *Tailscale) setBackendInitialized(err error) {
	t.backendInitOnce.Do(func() {
		t.backendInitErr = err
		close(t.backendInitCh)
	})
}

func (t *Tailscale) waitBackendInitialized(ctx context.Context) error {
	select {
	case <-t.backendInitCh:
		return t.backendInitErr
	case <-ctx.Done():
		return ctx.Err()
	case <-t.ctx.Done():
		return t.ctx.Err()
	}
}

func (t *Tailscale) applyPrefs(ctx context.Context) error {
	mp, err := buildTailscaleMaskedPrefs(t.option)
	if err != nil {
		return err
	}
	if mp == nil {
		return nil
	}
	lc, err := t.server.LocalClient()
	if err != nil {
		return err
	}
	_, err = lc.EditPrefs(ctx, mp)
	return err
}

func (t *Tailscale) applyExitNodePrefs(ctx context.Context) error {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()

	lc, err := t.server.LocalClient()
	if err != nil {
		return err
	}
	status, err := lc.Status(ctx)
	if err != nil {
		return err
	}
	mp := &ipn.MaskedPrefs{
		ExitNodeIPSet: true,
	}
	if t.option.ExitNodeAllowLANAccess != nil {
		mp.ExitNodeAllowLANAccess = *t.option.ExitNodeAllowLANAccess
		mp.ExitNodeAllowLANAccessSet = true
	}
	if err = mp.SetExitNodeIP(t.option.ExitNode, status); err != nil {
		return err
	}
	_, err = lc.EditPrefs(ctx, mp)
	return err
}

func buildTailscaleMaskedPrefs(option TailscaleOption) (*ipn.MaskedPrefs, error) {
	var mp ipn.MaskedPrefs
	changed := false

	if option.AcceptRoutes != nil {
		mp.RouteAll = *option.AcceptRoutes
		mp.RouteAllSet = true
		changed = true
	}
	if option.ExitNode != "" {
		if autoExitNode, ok := ipn.ParseAutoExitNodeString(option.ExitNode); ok {
			mp.AutoExitNode = autoExitNode
			mp.AutoExitNodeSet = true
			changed = true
		}
	}
	if option.ExitNodeAllowLANAccess != nil && !tailscaleExitNodeNeedsStatus(option) {
		mp.ExitNodeAllowLANAccess = *option.ExitNodeAllowLANAccess
		mp.ExitNodeAllowLANAccessSet = true
		changed = true
	}
	if !changed {
		return nil, nil
	}
	return &mp, nil
}

func tailscaleExitNodeNeedsStatus(option TailscaleOption) bool {
	if option.ExitNode == "" {
		return false
	}
	_, ok := ipn.ParseAutoExitNodeString(option.ExitNode)
	return !ok
}

func (t *Tailscale) DialContext(ctx context.Context, metadata *C.Metadata) (_ C.Conn, err error) {
	if err = t.ensureStarted(ctx); err != nil {
		return nil, err
	}
	netStack, err := t.server.Netstack(ctx)
	if err != nil {
		return nil, err
	}
	v4, v6 := t.server.TailscaleIPs()
	options := t.DialOptions()
	options = append(options, dialer.WithResolver(t.dnsResolver))
	options = append(options, dialer.WithNetDialer(dialer.NetDialerFunc(func(ctx context.Context, network, address string) (net.Conn, error) {
		dst, err := netip.ParseAddrPort(address) // the dialer will resolve the domain to ip
		if err != nil {
			return nil, err
		}
		src := v4
		if dst.Addr().Is6() {
			src = v6
		}
		tcpConn, err := netStack.DialContextTCPWithBind(ctx, src, dst)
		if err != nil {
			return nil, err
		}
		return tcpConn, nil
	})))
	var conn net.Conn
	conn, err = dialer.NewDialer(options...).DialContext(ctx, "tcp", metadata.RemoteAddress())
	if err != nil {
		return nil, err
	}
	if conn == nil {
		return nil, errors.New("conn is nil")
	}
	return NewConn(conn, t), nil
}

func (t *Tailscale) ListenPacketContext(ctx context.Context, metadata *C.Metadata) (_ C.PacketConn, err error) {
	if err = t.ensureStarted(ctx); err != nil {
		return nil, err
	}
	if err = t.ResolveUDP(ctx, metadata); err != nil {
		return nil, err
	}
	v4, v6 := t.server.TailscaleIPs()
	src := v4
	if metadata.DstIP.Is6() {
		src = v6
	}
	pc, err := t.server.ListenPacket("udp", net.JoinHostPort(src.String(), "0"))
	if err != nil {
		return nil, err
	}
	if pc == nil {
		return nil, errors.New("packetConn is nil")
	}
	return NewPacketConn(pc, t), nil
}

func (t *Tailscale) ResolveUDP(ctx context.Context, metadata *C.Metadata) error {
	if metadata.Host != "" {
		ip, err := resolveIPWithResolver(ctx, metadata.Host, t.prefer, t.dnsResolver)
		if err != nil {
			return fmt.Errorf("can't resolve ip: %w", err)
		}
		metadata.DstIP = ip
	}
	return nil
}

type tailscaleDNSTransport struct {
	tailscale *Tailscale
}

func (t tailscaleDNSTransport) Address() string {
	return "tailscale://" + t.tailscale.Name()
}

func (t tailscaleDNSTransport) ResetConnection() {}

func (t tailscaleDNSTransport) ExchangeContext(ctx context.Context, msg *D.Msg) (*D.Msg, error) {
	if len(msg.Question) == 0 {
		return nil, errors.New("should have one question at least")
	}
	if err := t.tailscale.ensureStarted(ctx); err != nil {
		return nil, err
	}
	q := msg.Question[0]
	qtypeName, ok := D.TypeToString[q.Qtype]
	if !ok {
		return nil, fmt.Errorf("unsupported query type: %d", q.Qtype)
	}
	lc, err := t.tailscale.server.LocalClient()
	if err != nil {
		return nil, err
	}
	response, _, err := lc.QueryDNS(ctx, q.Name, qtypeName)
	if err != nil {
		return nil, err
	}
	var responseMsg D.Msg
	if err = responseMsg.Unpack(response); err != nil {
		return nil, err
	}
	responseMsg.Id = msg.Id
	return &responseMsg, nil
}

func (t *Tailscale) ProxyInfo() C.ProxyInfo {
	info := t.Base.ProxyInfo()
	info.DialerProxy = t.option.DialerProxy
	return info
}

func (t *Tailscale) IsL3Protocol(metadata *C.Metadata) bool {
	return true
}

func (t *Tailscale) Close() error {
	t.closeOnce.Do(func() {
		t.cancel()
		t.running.Store(false)
		unregisterTailscaleInstance(t)
		if t.unregisterDNSResolver != nil {
			t.unregisterDNSResolver()
		}
		t.startOnce.Do(func() {
			t.startErr = errors.New("tailscale outbound closed")
		})
		// tsnet.Server.Close() 不能在 Start 之前或并发调用；
		// 用 closeOnce 保证只关一次，避免 "use of closed network connection"。
		if t.server != nil && t.serverStarted {
			t.closeErr = t.server.Close()
		}
	})
	return t.closeErr
}

// CloseIdle 实现 outbound.IdleCloser —— 但这里**不能真的关闭 tsnet**。
//
// 踩过的坑：一开始把 CloseIdle 写成等价于 Close，结果 Tailscale 刚登录成功
// （拿到 100.x 地址）十几秒后就被杀掉，状态变成「配置文件里没有 tailscale
// 出站」，节点彻底不可用。
//
// 原因：IdleCloser 的语义是「连接空闲时释放底层资源」，mihomo 会在
// 健康检查后、配置重建时调用它。而 tsnet 是**常驻**的用户态网络栈，
// 内核 netmap 长连接本身就不是「空转」，不能因为没有被 dial 就拆掉。
//
// 关闭开关时的正确清理路径由 core 负责：setupConfig 会用新配置重建
// tunnel，旧实例随之从 proxies 表中消失并被 GC 回收（Close 由 mihomo 的
// autoCloseProxyAdapter + finalizer 处理）。这里保持空实现即可。
func (t *Tailscale) CloseIdle() {}

// 编译期确认实现了 IdleCloser
var _ IdleCloser = (*Tailscale)(nil)

// TailscaleStatus 是给上层（Bettbox UI）用的状态快照，
// 只暴露需要的字段，避免把 tailscale 的内部类型泄漏到 core。
type TailscaleStatus struct {
	Name        string   `json:"name"`
	State       string   `json:"state"` // idle / starting / error / NeedsLogin / Running ...
	Hostname    string   `json:"hostname"`
	DNSName     string   `json:"dns-name"`
	IPs         []string `json:"ips"`
	PeerCount   int      `json:"peer-count"`
	OnlinePeers int      `json:"online-peers"`
	AuthURL     string   `json:"auth-url"`
	Health      []string `json:"health"`
	MagicDNS    string   `json:"magic-dns"`
	ExitNode    string   `json:"exit-node"`
	DialerProxy string   `json:"dialer-proxy"`
	Version     string   `json:"version"`
	Error       string   `json:"error,omitempty"`
}

// Started 报告 tsnet 是否已经启动（不论是否登录成功）。
func (t *Tailscale) Started() bool {
	return t.running.Load()
}

// StartAsync 在后台启动节点，供 UI 的「连接」按钮使用：
// 配置里的出站默认是懒启动的，这里可以提前把它拉起来，
// 从而让状态面板立刻显示 NeedsLogin / Running 等状态。
func (t *Tailscale) StartAsync() {
	go func() {
		if err := t.start(); err != nil {
			t.lastStartErr.Store(err.Error())
			log.Warnln("[Tailscale](%s) start failed: %v", t.Name(), err)
		}
	}()
}

// filterFakeIPs 去掉 FakeIP 网段里的地址。
//
// tsnet 把解析结果当作真实对端地址直接 dial，拿到 198.18.x.x（FakeIP）
// 就会去连一个不存在的主机，表现为登录一直超时：
//
//	LookupHook: finish lookup controlplane.tailscale.com, ips: [198.18.0.4]
//	SystemDialer: finish dial tcp 198.18.0.4:443, err: operation was canceled
//
// fake-ip-filter 已在配置层规避，这里再兜一层，避免用户自建配置漏配。
func filterFakeIPs(host string, ips []netip.Addr) []netip.Addr {
	if len(ips) == 0 || !resolver.FakeIPEnabled() {
		return nil
	}
	real := make([]netip.Addr, 0, len(ips))
	for _, ip := range ips {
		if resolver.IsFakeIP(ip) {
			continue
		}
		real = append(real, ip)
	}
	if len(real) != len(ips) {
		log.Debugln("[Tailscale] LookupHook: dropped %d fake ip(s) for %s", len(ips)-len(real), host)
	}
	return real
}

// Status 返回节点状态。未启动时返回 idle，不会阻塞在首次登录上。
//
// 这里做了三层防护：panic 转 error、status 失败时退化为不带 peers 的查询、
// 失败原因一定带上，避免上层只看到一个空错误。
func (t *Tailscale) Status(ctx context.Context) (status *TailscaleStatus, err error) {
	status = &TailscaleStatus{
		Name:        t.Name(),
		Hostname:    t.option.Hostname,
		ExitNode:    t.option.ExitNode,
		DialerProxy: t.option.DialerProxy,
		State:       "idle",
	}
	defer func() {
		if r := recover(); r != nil {
			status.State = "error"
			status.Error = fmt.Sprintf("panic in status: %v", r)
			err = errors.New(status.Error)
			log.Warnln("[Tailscale](%s) %s", t.Name(), status.Error)
		}
	}()
	if !t.running.Load() {
		if v := t.lastStartErr.Load(); v != nil {
			status.State = "error"
			status.Error, _ = v.(string)
		}
		return status, nil
	}

	status.State = "starting"
	lc, err := t.server.LocalClient()
	if err != nil {
		status.State = "error"
		status.Error = err.Error()
		log.Warnln("[Tailscale](%s) localapi client: %v", t.Name(), err)
		return status, err
	}
	st, err := lc.Status(ctx)
	if err != nil {
		// 大 tailnet 上 /status 要序列化全部 peer，可能超时；
		// 退化到不带 peers 的查询，至少把 IP / 状态拿到。
		log.Warnln("[Tailscale](%s) lc.Status failed: %v, retry without peers", t.Name(), err)
		st, err = lc.StatusWithoutPeers(ctx)
		if err != nil {
			status.State = "error"
			status.Error = err.Error()
			log.Warnln("[Tailscale](%s) lc.StatusWithoutPeers failed: %v", t.Name(), err)
			return status, err
		}
	}

	status.State = st.BackendState
	status.Version = st.Version
	status.AuthURL = st.AuthURL
	status.Health = st.Health
	if st.Self != nil {
		if st.Self.HostName != "" {
			status.Hostname = st.Self.HostName
		}
		status.DNSName = st.Self.DNSName
	}
	for _, ip := range st.TailscaleIPs {
		status.IPs = append(status.IPs, ip.String())
	}
	status.PeerCount = len(st.Peer)
	for _, peer := range st.Peer {
		if peer != nil && peer.Online {
			status.OnlinePeers++
		}
	}
	if st.CurrentTailnet != nil && st.CurrentTailnet.MagicDNSSuffix != "" {
		status.MagicDNS = st.CurrentTailnet.MagicDNSSuffix
	} else {
		status.MagicDNS = st.MagicDNSSuffix
	}
	return status, nil
}

// fileExists 判断路径是否是存在的普通文件。
func fileExists(path string) bool {
	info, err := os.Stat(path)
	return err == nil && !info.IsDir()
}

// Logout 让本节点退出 tailnet，并清空本地登录态。
//
// 存在的理由：登录态（node key）保存在 state-dir 里，只要那个目录还在、
// node key 还有效，tsnet 重启后会直接恢复登录。因此「把 auth-key 从配置里
// 删掉」并不会让节点退出——它只是不再用 key 去自动授权，已经登录的身份仍然
// 有效。用户删 key 的意图通常是「换账号」或「重新授权」，所以需要一个显式
// 的登出动作。
//
// 做两件事：
//  1. 通过 LocalClient 调 Logout，让 control plane 侧也解除绑定；
//  2. 删除 state-dir（里面是 node key / prefs），保证下次 Start 是全新节点，
//     会重新走 NeedsLogin 并给出一条新的 auth-url。
//
// 只删目录不调 Logout 会在 tailnet 里留下一个永远离线的僵尸设备，所以两步都要做。
func (t *Tailscale) Logout(ctx context.Context) error {
	var errs []string
	if t.server != nil && t.serverStarted {
		if lc, err := t.server.LocalClient(); err == nil {
			if err := lc.Logout(ctx); err != nil {
				errs = append(errs, fmt.Sprintf("logout: %v", err))
			} else {
				log.Infoln("[Tailscale](%s) logged out from control plane", t.Name())
			}
		}
	}
	// 先停掉 tsnet，避免它在目录被删后又写回去。
	if err := t.Close(); err != nil {
		errs = append(errs, fmt.Sprintf("close: %v", err))
	}
	if dir := t.option.StateDir; dir != "" {
		if err := os.RemoveAll(dir); err != nil {
			errs = append(errs, fmt.Sprintf("remove state dir: %v", err))
		} else {
			log.Infoln("[Tailscale](%s) state dir cleared: %s", t.Name(), filepath.Clean(dir))
		}
	}
	if len(errs) > 0 {
		return errors.New(strings.Join(errs, "; "))
	}
	return nil
}

var (
	tailscaleInstancesMu sync.RWMutex
	tailscaleInstances   = map[string]*Tailscale{}
)

func registerTailscaleInstance(t *Tailscale) {
	tailscaleInstancesMu.Lock()
	tailscaleInstances[t.Name()] = t
	tailscaleInstancesMu.Unlock()
}

func unregisterTailscaleInstance(t *Tailscale) {
	tailscaleInstancesMu.Lock()
	if current, ok := tailscaleInstances[t.Name()]; ok && current == t {
		delete(tailscaleInstances, t.Name())
	}
	tailscaleInstancesMu.Unlock()
}

// TailscaleInstances 返回当前配置里所有 tailscale 出站（按名字排序）。
func TailscaleInstances() []*Tailscale {
	tailscaleInstancesMu.RLock()
	names := make([]string, 0, len(tailscaleInstances))
	for name := range tailscaleInstances {
		names = append(names, name)
	}
	sort.Strings(names)
	instances := make([]*Tailscale, 0, len(names))
	for _, name := range names {
		instances = append(instances, tailscaleInstances[name])
	}
	tailscaleInstancesMu.RUnlock()
	return instances
}

// GetTailscaleInstance 按名字取 tailscale 出站，名字为空时返回第一个。
func GetTailscaleInstance(name string) *Tailscale {
	instances := TailscaleInstances()
	if name == "" {
		if len(instances) == 0 {
			return nil
		}
		return instances[0]
	}
	for _, instance := range instances {
		if instance.Name() == name {
			return instance
		}
	}
	return nil
}
