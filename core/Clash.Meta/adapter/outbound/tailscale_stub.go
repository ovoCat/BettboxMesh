//go:build !with_gvisor || no_tailscale

package outbound

import (
	"context"
	"fmt"
)

type Tailscale struct {
	*Base
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

func NewTailscale(option TailscaleOption) (*Tailscale, error) {
	return nil, fmt.Errorf("tailscale support is disabled by \"no_tailscale\" build tag or not include \"with_gvisor\" build tag")
}

// TailscaleStatus mirrors the real implementation so that the bridge code in
// core stays build-tag agnostic (lite builds use no_tailscale).
type TailscaleStatus struct {
	Name        string   `json:"name"`
	State       string   `json:"state"`
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

func (t *Tailscale) Started() bool {
	return false
}

func (t *Tailscale) StartAsync() {}

// CloseIdle 与真实实现保持同名同签名，保证 no_tailscale 构建也能编译。
// 该构建下没有实例，什么都不用做。
func (t *Tailscale) CloseIdle() {}

// Logout 在 no_tailscale 构建下无需处理。
func (t *Tailscale) Logout(ctx context.Context) error {
	return fmt.Errorf("tailscale support is disabled")
}

var _ IdleCloser = (*Tailscale)(nil)

func (t *Tailscale) Status(ctx context.Context) (*TailscaleStatus, error) {
	if t == nil {
		return nil, fmt.Errorf("tailscale support is disabled")
	}
	return &TailscaleStatus{
		Name:  t.Name(),
		State: "unsupported",
		Error: "tailscale support is disabled by build tag",
	}, nil
}

func TailscaleInstances() []*Tailscale {
	return nil
}

func GetTailscaleInstance(name string) *Tailscale {
	return nil
}
