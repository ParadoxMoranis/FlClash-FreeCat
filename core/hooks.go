package core

import (
	"sync"
	"time"

	"github.com/metacubex/mihomo/adapter"
	mihomoHttp "github.com/metacubex/mihomo/component/http"
	"github.com/metacubex/mihomo/component/proxydialer"
	"github.com/metacubex/mihomo/component/updater"
	"github.com/metacubex/mihomo/dns"
	"github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

func init() {
	mihomoHttp.TLSConfigHook = relaxCertVerify
	adapter.UrlTestHook = func(proxy *adapter.Proxy, url string) func(uint16, bool) {
		state := activeDelayConfig.Load()
		if state != nil && !state.ready {
			return nil
		}
		return func(delay uint16, timedOut bool) {
			if !delayTestIsCurrent(proxy, state) {
				return
			}
			sendMessage(DelayMessage, &Delay{
				Url:        url,
				Name:       proxy.Name(),
				Value:      delayValue(delay, timedOut),
				Generation: delayGenerationValue(state),
			})
		}
	}
	statistic.DefaultRequestNotify = func(c statistic.Tracker) {
		notifyProbeRoute(c)
		if hasEventListener() {
			sendMessage(RequestMessage, c)
			watchRequestTraffic(c)
		}
	}
	dns.DefaultQueryNotify = func(record dns.QueryRecord) {
		if hasEventListener() {
			sendMessage(DnsMessage, newDnsQuery(record))
		}
	}
	executor.DefaultProviderLoadedHook = func(providerName string) {
		scheduleReclaimOwnership()
		scheduleLoadMemoryRelease()
		sendMessage(LoadedMessage, providerName)
	}
	updater.GeoUpdateHook = onGeoUpdate
	proxydialer.DefaultLoopNotify = reportDialerLoop
}

// Every dial through a looping dialer fails; one report stands for the burst.
const dialerLoopReportInterval = 3 * time.Second

var dialerLoopReports sync.Map

func reportDialerLoop(proxyName string) {
	now := time.Now()
	if last, ok := dialerLoopReports.Load(proxyName); ok && now.Sub(last.(time.Time)) < dialerLoopReportInterval {
		return
	}
	dialerLoopReports.Store(proxyName, now)
	sendMessage(DialerLoopMessage, proxyName)
}
