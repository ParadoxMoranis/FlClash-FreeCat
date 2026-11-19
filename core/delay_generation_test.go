//go:build !cgo && !android

package core

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/common/utils"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/tunnel"
)

func TestApplyConfigPublishesDelayGenerationAfterTransition(t *testing.T) {
	keepTunnel(t)
	keepDelayGeneration(t)
	withCurrentConfig(t, nil)
	home := t.TempDir()
	previousHome := constant.Path.HomeDir()
	constant.SetHomeDir(home)
	t.Cleanup(func() { constant.SetHomeDir(previousHome) })
	if err := os.WriteFile(filepath.Join(home, "config.yaml"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	initial := &delayConfigState{generation: "old-generation", ready: true}
	activeDelayConfig.Store(initial)
	previousHook := executor.DefaultProviderLoadedHook
	defer func() { executor.DefaultProviderLoadedHook = previousHook }()
	observed := make(chan *delayConfigState, 8)
	executor.DefaultProviderLoadedHook = func(string) {
		observed <- activeDelayConfig.Load()
	}
	params := &SetupParams{DelayGeneration: "applied-generation"}
	if err := applyConfig(params); err != nil {
		t.Fatalf("applyConfig: %v", err)
	}
	if len(observed) == 0 {
		t.Fatal("apply never loaded its compatible provider")
	}
	for len(observed) > 0 {
		if state := <-observed; state == initial || state == nil || state.ready || state.generation != params.DelayGeneration {
			t.Errorf("delay state while ApplyConfig loads providers = %+v, want an inactive new generation", state)
		}
	}
	state := activeDelayConfig.Load()
	if state == initial || state == nil || !state.ready || state.generation != params.DelayGeneration {
		t.Fatalf("delay state after apply = %+v, want the active new generation", state)
	}
	params.DelayGeneration = "mutated-caller-params"
	if state.generation != "applied-generation" {
		t.Error("changing setup params mutated a published generation")
	}
	if err := applyConfig(&SetupParams{}); err != nil {
		t.Fatalf("legacy applyConfig: %v", err)
	}
	if current := activeDelayConfig.Load(); current == state || current == nil || !current.ready || current.generation != "" {
		t.Errorf("legacy apply delay state = %+v, want a fresh active empty generation", current)
	}
}

func TestDelayGenerationDiscardsProbesStartedDuringApply(t *testing.T) {
	keepTunnel(t)
	keepDelayGeneration(t)
	settleMessageBatcher()
	started := make(chan context.Context, 1)
	release := make(chan struct{})
	proxy := adapter.NewProxy(&blockedDelayDialer{
		ProxyAdapter: namedProxy("shared").Adapter(),
		started:      started,
		release:      release,
	})
	tunnel.UpdateProxies(map[string]constant.Proxy{"shared": proxy}, nil)
	activeDelayConfig.Store(&delayConfigState{generation: "new-generation"})

	frames := captureFrames(t, func() {
		if complete := adapter.UrlTestHook(proxy, "http://127.0.0.1:1"); complete != nil {
			t.Error("a probe begun during apply received a completion callback")
		}
		if delay := handleTestDelay(&TestDelayParams{ProxyName: "missing-during-apply", Timeout: 1000}); delay != nil {
			t.Errorf("a request made during apply returned %+v, want nil", delay)
		}
		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()
		done := make(chan struct{})
		go func() {
			defer close(done)
			_, _ = proxy.URLTest(ctx, "http://127.0.0.1:1", anyDelayTestStatus)
		}()
		select {
		case <-started:
		case <-time.After(time.Second):
			t.Fatal("background probe never started during apply")
		}
		activeDelayConfig.Store(&delayConfigState{generation: "new-generation", ready: true})
		cancel()
		close(release)
		select {
		case <-done:
		case <-time.After(time.Second):
			t.Fatal("transition probe never completed")
		}
		settleMessageBatcher()
	})
	if delays := delayEvents(t, frames); len(delays) != 0 {
		t.Errorf("probe begun during apply emitted results after activation: %+v", delays)
	}
}

type queuedDelayProxy struct {
	constant.Proxy
	captured chan struct{}
	tested   atomic.Bool
}

func (p *queuedDelayProxy) Name() string {
	select {
	case p.captured <- struct{}{}:
	default:
	}
	return p.Proxy.Name()
}

func (p *queuedDelayProxy) URLTest(context.Context, string, utils.IntRanges[uint16]) (uint16, error) {
	p.tested.Store(true)
	return 42, nil
}

func TestDelayGenerationDiscardsAQueuedProbeBeforeItStarts(t *testing.T) {
	for _, replaceProxy := range []bool{false, true} {
		name := "generation changed"
		if replaceProxy {
			name = "proxy changed"
		}
		t.Run(name, func(t *testing.T) {
			keepTunnel(t)
			keepDelayGeneration(t)
			generation := "queued-generation"
			activeDelayConfig.Store(&delayConfigState{generation: generation, ready: true})
			previousSlots := delayTestSlots
			delayTestSlots = make(slots, 1)
			delayTestSlots <- struct{}{}
			t.Cleanup(func() { delayTestSlots = previousSlots })
			proxy := &queuedDelayProxy{Proxy: namedProxy("shared"), captured: make(chan struct{}, 1)}
			tunnel.UpdateProxies(map[string]constant.Proxy{"shared": proxy}, nil)
			done := make(chan *Delay, 1)
			go func() {
				done <- handleTestDelay(&TestDelayParams{ProxyName: "shared", Timeout: 1000})
			}()
			select {
			case <-proxy.captured:
			case <-time.After(time.Second):
				t.Fatal("queued request never captured its proxy")
			}
			if replaceProxy {
				tunnel.UpdateProxies(map[string]constant.Proxy{"shared": namedProxy("shared")}, nil)
			} else {
				replacement := "replacement-generation"
				activeDelayConfig.Store(&delayConfigState{generation: replacement, ready: true})
			}
			<-delayTestSlots
			select {
			case delay := <-done:
				if delay != nil || proxy.tested.Load() {
					t.Errorf("queued stale request returned %+v, tested = %v; want nil without probing", delay, proxy.tested.Load())
				}
			case <-time.After(time.Second):
				t.Fatal("queued stale request never completed after a slot was released")
			}
		})
	}
}

func TestDelayGenerationDiscardsOldTimeoutEventsAndReplies(t *testing.T) {
	for _, replaceProxy := range []bool{false, true} {
		name := "same proxy"
		if replaceProxy {
			name = "same name, new proxy"
		}
		t.Run(name, func(t *testing.T) {
			keepTunnel(t)
			keepDelayGeneration(t)
			settleMessageBatcher()
			previous := "old-generation"
			activeDelayConfig.Store(&delayConfigState{generation: previous, ready: true})

			started := make(chan context.Context, 1)
			release := make(chan struct{})
			old := adapter.NewProxy(&blockedDelayDialer{
				ProxyAdapter: namedProxy("shared").Adapter(),
				started:      started,
				release:      release,
			})
			tunnel.UpdateProxies(map[string]constant.Proxy{"shared": old}, nil)

			frames := captureFrames(t, func() {
				done := make(chan *Delay, 1)
				go func() {
					done <- handleTestDelay(&TestDelayParams{
						ProxyName: "shared",
						TestUrl:   "http://127.0.0.1:1",
						Timeout:   50,
					})
				}()
				var ctx context.Context
				select {
				case ctx = <-started:
				case <-time.After(time.Second):
					t.Fatal("old probe never started")
				}

				current := "new-generation"
				activeDelayConfig.Store(&delayConfigState{generation: current, ready: true})
				if replaceProxy {
					tunnel.UpdateProxies(map[string]constant.Proxy{"shared": namedProxy("shared")}, nil)
				}
				<-ctx.Done()
				close(release)
				select {
				case delay := <-done:
					if delay != nil {
						t.Errorf("old generation reply = %+v, want nil", delay)
					}
				case <-time.After(time.Second):
					t.Fatal("old generation probe never completed")
				}
				settleMessageBatcher()
			})
			if delays := delayEvents(t, frames); len(delays) != 0 {
				t.Errorf("old generation emitted delay events: %+v", delays)
			}
		})
	}
}

func TestDelayGenerationAcceptsCurrentEventsAndReplies(t *testing.T) {
	keepTunnel(t)
	keepDelayGeneration(t)
	settleMessageBatcher()
	generation := "current-generation"
	activeDelayConfig.Store(&delayConfigState{generation: generation, ready: true})
	tunnel.UpdateProxies(map[string]constant.Proxy{"shared": namedProxy("shared")}, nil)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()

	frames := captureFrames(t, func() {
		delay := handleTestDelay(&TestDelayParams{ProxyName: "shared", TestUrl: server.URL, Timeout: 1000})
		if delay == nil || delay.Value <= 0 || delay.Generation != generation {
			t.Errorf("current generation reply = %+v, want a tagged successful result", delay)
		}
		settleMessageBatcher()
	})
	delays := delayEvents(t, frames)
	if len(delays) != 1 || delays[0].Value <= 0 || delays[0].Generation != generation {
		t.Errorf("current generation delay events = %+v, want one tagged successful result", delays)
	}
}

func TestDelayGenerationQueuedEventKeepsItsOriginalGeneration(t *testing.T) {
	keepTunnel(t)
	keepDelayGeneration(t)
	settleMessageBatcher()
	generation := "queued-generation"
	activeDelayConfig.Store(&delayConfigState{generation: generation, ready: true})
	proxy := namedProxy("shared").(*adapter.Proxy)
	tunnel.UpdateProxies(map[string]constant.Proxy{"shared": proxy}, nil)

	frames := captureFrames(t, func() {
		complete := adapter.UrlTestHook(proxy, "http://127.0.0.1:1")
		complete(42, false)
		replacement := "replacement-generation"
		activeDelayConfig.Store(&delayConfigState{generation: replacement, ready: true})
		settleMessageBatcher()
	})
	delays := delayEvents(t, frames)
	if len(delays) != 1 || delays[0].Generation != generation || delays[0].Value != 42 {
		t.Errorf("queued delay events = %+v, want the original generation preserved", delays)
	}
}

func TestDelayHookDoesNotWaitForConfigApplyMutex(t *testing.T) {
	keepTunnel(t)
	proxy := namedProxy("shared").(*adapter.Proxy)
	tunnel.UpdateProxies(map[string]constant.Proxy{"shared": proxy}, nil)
	configMu.Lock()
	done := make(chan struct{})
	go func() {
		complete := adapter.UrlTestHook(proxy, "http://127.0.0.1:1")
		complete(1, false)
		close(done)
	}()
	select {
	case <-done:
		configMu.Unlock()
	case <-time.After(time.Second):
		configMu.Unlock()
		<-done
		t.Fatal("delay hook blocked on configMu while ApplyConfig could be waiting for its health checks")
	}
	settleMessageBatcher()
}

func TestDelayGenerationProtocolKeepsLegacyPayloadsCompatible(t *testing.T) {
	var legacy SetupParams
	if err := json.Unmarshal([]byte(`{"options":{},"selected-map":{}}`), &legacy); err != nil {
		t.Fatal(err)
	}
	if legacy.DelayGeneration != "" {
		t.Errorf("legacy setup generation = %q, want empty", legacy.DelayGeneration)
	}
	for _, value := range []any{SetupParams{}, Delay{}} {
		encoded, err := json.Marshal(value)
		if err != nil {
			t.Fatal(err)
		}
		var fields map[string]json.RawMessage
		if err := json.Unmarshal(encoded, &fields); err != nil {
			t.Fatal(err)
		}
		if fields["generation"] != nil || fields["delay-generation"] != nil {
			t.Errorf("legacy payload contains a generation field: %s", encoded)
		}
	}
	var setup SetupParams
	if err := json.Unmarshal([]byte(`{"delay-generation":"new-generation"}`), &setup); err != nil {
		t.Fatal(err)
	}
	if setup.DelayGeneration != "new-generation" {
		t.Errorf("setup generation = %q, want new-generation", setup.DelayGeneration)
	}
}
