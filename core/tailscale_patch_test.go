package main

import (
	"testing"
)

const tailscalePatchProfile = `
proxies:
  - name: NodeA
    type: ss
    server: 1.1.1.1
    port: 8388
    cipher: aes-128-gcm
    password: pass
proxy-groups:
  - name: Proxy
    type: select
    proxies: [NodeA]
rules:
  - DOMAIN-SUFFIX,example.com,Proxy
  - MATCH,Proxy
dns:
  enable: true
  nameserver:
    - 8.8.8.8
`

func TestPatchTailscaleInjectsProxyRulesAndDNS(t *testing.T) {
	raw := parsePatchProfile(t, tailscalePatchProfile)
	params := patchParams(t, `{
	  "tailscale": {
	    "enable": true,
	    "name": "TS",
	    "auth-key": "tskey-auth-xxx",
	    "hostname": "phone",
	    "route-rules": true,
	    "magic-dns": true
	  }
	}`)

	if _, err := applyPatch(raw, params); err != nil {
		t.Fatalf("applyPatch: %v", err)
	}

	if len(raw.Proxy) != 2 {
		t.Fatalf("expected 2 proxies, got %d", len(raw.Proxy))
	}
	injected := raw.Proxy[0]
	if injected["name"] != "TS" {
		t.Fatalf("tailscale proxy should be injected first, got %v", injected["name"])
	}
	if injected["type"] != "tailscale" {
		t.Fatalf("unexpected type: %v", injected["type"])
	}
	if _, ok := injected["dialer-proxy"]; ok {
		t.Fatalf("dialer-proxy must never be injected now, got %v", injected["dialer-proxy"])
	}
	if injected["auth-key"] != "tskey-auth-xxx" {
		t.Fatalf("auth-key not propagated: %v", injected["auth-key"])
	}
	if injected["hostname"] != "phone" {
		t.Fatalf("hostname not propagated: %v", injected["hostname"])
	}

	wantRules := []string{
		"IP-CIDR,100.64.0.0/10,TS,no-resolve",
		"IP-CIDR6,fd7a:115c:a1e0::/48,TS,no-resolve",
		"DOMAIN-SUFFIX,ts.net,TS",
		"DOMAIN-SUFFIX,example.com,Proxy",
		"MATCH,Proxy",
	}
	if len(raw.Rule) != len(wantRules) {
		t.Fatalf("unexpected rules: %v", raw.Rule)
	}
	for i, want := range wantRules {
		if raw.Rule[i] != want {
			t.Errorf("rule[%d] = %q, want %q", i, raw.Rule[i], want)
		}
	}

	if raw.DNS.NameServerPolicy == nil {
		t.Fatal("nameserver-policy should be created for MagicDNS")
	}
	value, ok := raw.DNS.NameServerPolicy.Get("+.ts.net")
	if !ok {
		t.Fatalf("nameserver-policy should contain +.ts.net, got %v", raw.DNS.NameServerPolicy)
	}
	if value != "tailscale://TS" {
		t.Fatalf("unexpected nameserver policy value: %v", value)
	}
}

func TestPatchTailscaleIgnoresLegacyDialerProxy(t *testing.T) {
	raw := parsePatchProfile(t, tailscalePatchProfile)
	// 旧配置里可能还留着 dialer-proxy，必须被忽略而不是注入
	params := patchParams(t, `{"tailscale": {"enable": true, "name": "TS", "route-rules": true, "dialer-proxy": "Proxy"}}`)

	if _, err := applyPatch(raw, params); err != nil {
		t.Fatalf("applyPatch: %v", err)
	}

	injected := raw.Proxy[0]
	if _, ok := injected["dialer-proxy"]; ok {
		t.Fatalf("legacy dialer-proxy must be ignored, got %v", injected["dialer-proxy"])
	}
	// MagicDNS 默认关闭（未下发 magic-dns），不应改写 DNS
	if raw.DNS.NameServerPolicy != nil {
		if _, ok := raw.DNS.NameServerPolicy.Get("+.ts.net"); ok {
			t.Fatal("nameserver-policy should stay untouched when magic-dns is off")
		}
	}
}

func TestPatchTailscaleDisabledKeepsConfig(t *testing.T) {
	raw := parsePatchProfile(t, tailscalePatchProfile)
	params := patchParams(t, `{"tailscale": {"enable": false, "name": "TS"}}`)

	if _, err := applyPatch(raw, params); err != nil {
		t.Fatalf("applyPatch: %v", err)
	}
	if len(raw.Proxy) != 1 {
		t.Fatalf("disabled tailscale must not touch proxies, got %d", len(raw.Proxy))
	}
	if raw.Rule[0] != "DOMAIN-SUFFIX,example.com,Proxy" {
		t.Fatalf("disabled tailscale must not touch rules, got %v", raw.Rule[0])
	}
}

func TestPatchTailscaleNameCollision(t *testing.T) {
	raw := parsePatchProfile(t, `
proxies:
  - name: TS
    type: ss
    server: 1.1.1.1
    port: 8388
    cipher: aes-128-gcm
    password: pass
rules:
  - MATCH,DIRECT
`)
	params := patchParams(t, `{"tailscale": {"enable": true, "name": "TS", "route-rules": true}}`)

	if _, err := applyPatch(raw, params); err != nil {
		t.Fatalf("applyPatch: %v", err)
	}
	if len(raw.Proxy) != 2 {
		t.Fatalf("expected the tailscale proxy to be added under a new name, got %v", raw.Proxy)
	}
	if raw.Proxy[0]["name"] != "TS Tailscale" {
		t.Fatalf("unexpected fallback name: %v", raw.Proxy[0]["name"])
	}
	if raw.Rule[0] != "IP-CIDR,100.64.0.0/10,TS Tailscale,no-resolve" {
		t.Fatalf("rules should target the fallback name, got %v", raw.Rule[0])
	}
}

func TestPatchTailscaleDNSSuffix(t *testing.T) {
	raw := parsePatchProfile(t, tailscalePatchProfile)
	params := patchParams(t, `{"tailscale": {
	  "enable": true,
	  "name": "TS",
	  "route-rules": true,
	  "magic-dns": true,
	  "dns-suffix": "Tailnet.Example.com."
	}}`)

	if _, err := applyPatch(raw, params); err != nil {
		t.Fatalf("applyPatch: %v", err)
	}
	if raw.Rule[3] != "DOMAIN-SUFFIX,tailnet.example.com,TS" {
		t.Fatalf("custom dns suffix rule missing, got %v", raw.Rule[3])
	}
	if _, ok := raw.DNS.NameServerPolicy.Get("+.tailnet.example.com"); !ok {
		t.Fatal("nameserver-policy should contain the custom suffix")
	}
}

func TestPatchTailscaleFakeIPFilter(t *testing.T) {
	raw := parsePatchProfile(t, tailscalePatchProfile)
	params := patchParams(t, `{"tailscale": {"enable": true, "name": "TS"}}`)

	if _, err := applyPatch(raw, params); err != nil {
		t.Fatalf("applyPatch: %v", err)
	}

	want := map[string]bool{
		"controlplane.tailscale.com": true,
		"login.tailscale.com":        true,
		"derp.tailscale.com":         true,
		"log.tailscale.io":           true,
		"log.tailscale.com":          true,
	}
	got := map[string]bool{}
	for _, entry := range raw.DNS.FakeIPFilter {
		got[entry] = true
	}
	for domain := range want {
		if !got[domain] {
			t.Errorf("fake-ip-filter missing %q, got %v", domain, raw.DNS.FakeIPFilter)
		}
	}
	// 控制面域名必须排在 ts.net 之前被判定，且不能被 fakeip 劫持
	if len(raw.DNS.FakeIPFilter) == 0 {
		t.Fatal("fake-ip-filter should not be empty")
	}
}

func TestPatchTailscaleFakeIPFilterHeadscale(t *testing.T) {
	raw := parsePatchProfile(t, tailscalePatchProfile)
	params := patchParams(t, `{"tailscale": {
	  "enable": true,
	  "name": "TS",
	  "control-url": "https://headscale.example.com:8443"
	}}`)

	if _, err := applyPatch(raw, params); err != nil {
		t.Fatalf("applyPatch: %v", err)
	}

	found := false
	for _, entry := range raw.DNS.FakeIPFilter {
		if entry == "headscale.example.com" {
			found = true
		}
	}
	if !found {
		t.Fatalf("headscale control host should bypass fakeip, got %v", raw.DNS.FakeIPFilter)
	}
}

func TestPatchTailscaleFakeIPFilterNoDuplicate(t *testing.T) {
	raw := parsePatchProfile(t, tailscalePatchProfile)
	// 预置一个同名条目，确认不会重复追加
	raw.DNS.FakeIPFilter = append(raw.DNS.FakeIPFilter, "controlplane.tailscale.com")
	params := patchParams(t, `{"tailscale": {"enable": true, "name": "TS"}}`)

	if _, err := applyPatch(raw, params); err != nil {
		t.Fatalf("applyPatch: %v", err)
	}

	count := 0
	for _, entry := range raw.DNS.FakeIPFilter {
		if entry == "controlplane.tailscale.com" {
			count++
		}
	}
	if count != 1 {
		t.Fatalf("controlplane.tailscale.com should appear once, got %d", count)
	}
}

func TestControlURLHost(t *testing.T) {
	cases := map[string]string{
		"https://headscale.example.com:8443": "headscale.example.com",
		"https://headscale.example.com":      "headscale.example.com",
		"https://198.51.100.7:8443":          "",
		"":                                   "",
		"not a url":                          "",
	}
	for input, want := range cases {
		if got := controlURLHost(input); got != want {
			t.Errorf("controlURLHost(%q) = %q, want %q", input, got, want)
		}
	}
}
