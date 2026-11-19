//go:build !cgo && !android

package core

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel"
)

type blockedDelayDialer struct {
	constant.ProxyAdapter
	started chan context.Context
	release <-chan struct{}
}

func (p *blockedDelayDialer) DialContext(ctx context.Context, _ *constant.Metadata) (constant.Conn, error) {
	p.started <- ctx
	<-p.release
	<-ctx.Done()
	return nil, ctx.Err()
}

func delayEvents(t *testing.T, frames [][]byte) []Delay {
	t.Helper()
	var delays []Delay
	for _, frame := range frames {
		var envelope struct {
			Arguments []struct {
				Type MessageType     `json:"type"`
				Data json.RawMessage `json:"data"`
			} `json:"arguments"`
		}
		if err := json.Unmarshal(frame, &envelope); err != nil {
			t.Fatalf("decode event frame: %v", err)
		}
		for _, event := range envelope.Arguments {
			if event.Type != DelayMessage {
				continue
			}
			var delay Delay
			if err := json.Unmarshal(event.Data, &delay); err != nil {
				t.Fatalf("decode delay event: %v", err)
			}
			delays = append(delays, delay)
		}
	}
	return delays
}

func TestDelayHookDiscardsAnOldProxyTimeoutAfterReplacement(t *testing.T) {
	keepTunnel(t)
	settleMessageBatcher()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()

	started := make(chan context.Context, 1)
	release := make(chan struct{})
	old := adapter.NewProxy(&blockedDelayDialer{
		ProxyAdapter: namedProxy("shared").Adapter(),
		started:      started,
		release:      release,
	})
	tunnel.UpdateProxies(map[string]constant.Proxy{"shared": old}, nil)

	frames := captureFrames(t, func() {
		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()
		done := make(chan struct{})
		go func() {
			defer close(done)
			_, _ = old.URLTest(ctx, server.URL, anyDelayTestStatus)
		}()
		select {
		case <-started:
		case <-time.After(time.Second):
			t.Fatal("old probe never entered DialContext")
		}

		current := namedProxy("shared")
		tunnel.UpdateProxies(map[string]constant.Proxy{"shared": current}, nil)
		cancel()
		close(release)
		select {
		case <-done:
		case <-time.After(time.Second):
			t.Fatal("old probe did not finish after cancellation")
		}
		if _, err := current.URLTest(context.Background(), server.URL, anyDelayTestStatus); err != nil {
			t.Fatalf("current probe failed: %v", err)
		}
		if len(current.DelayHistory()) != 1 || current.DelayHistory()[0].Delay == 0 {
			t.Errorf("current proxy history = %+v, want only its successful probe", current.DelayHistory())
		}
		settleMessageBatcher()
	})

	delays := delayEvents(t, frames)
	if len(delays) != 1 || delays[0].Name != "shared" || delays[0].Value <= 0 {
		t.Fatalf("delay events = %+v, want only the replacement proxy's successful probe", delays)
	}
}

func TestTestDelayDiscardsAnOldProxyTimeoutAfterReplacement(t *testing.T) {
	keepTunnel(t)
	started := make(chan context.Context, 1)
	release := make(chan struct{})
	old := adapter.NewProxy(&blockedDelayDialer{
		ProxyAdapter: namedProxy("shared").Adapter(),
		started:      started,
		release:      release,
	})
	tunnel.UpdateProxies(map[string]constant.Proxy{"shared": old}, nil)

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
		t.Fatal("old probe never entered DialContext")
	}
	tunnel.UpdateProxies(map[string]constant.Proxy{"shared": namedProxy("shared")}, nil)
	<-ctx.Done()
	close(release)
	select {
	case delay := <-done:
		if delay != nil {
			t.Fatalf("old probe result = %+v, want no verdict on the replacement proxy", delay)
		}
	case <-time.After(time.Second):
		t.Fatal("old probe did not return after its deadline")
	}
	settleMessageBatcher()
}
