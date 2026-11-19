const freecatClientFingerprint = 'chrome120';

Map<String, dynamic> withFreecatTlsCompatibility(Map<String, dynamic> config) {
  final proxies = config['proxies'];
  if (proxies is! List) return config;
  return {
    ...config,
    'proxies': [
      for (final proxy in proxies)
        if (proxy is Map &&
            proxy['type'] == 'trojan' &&
            !proxy.containsKey('client-fingerprint') &&
            (proxy['network'] == null || proxy['network'] == 'tcp'))
          {...proxy, 'client-fingerprint': freecatClientFingerprint}
        else
          proxy,
    ],
  };
}
