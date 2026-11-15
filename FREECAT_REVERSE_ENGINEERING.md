# 自由猫（FreeCat / ziyoumao 3.1.0）逆向总览与 FlClash 适配手册

> 目标：把已经确认的协议、加密、订阅格式、官方客户端行为和踩坑点整理成一份
> 可以直接交给另一个 AI / 工程师去魔改 FlClash 的资料。
>
> 所有账号相关的值（账号 UUID、token、订阅 URL、节点密码）都不在本文中。
> 节点服务器域名也做了脱敏；订阅本身会下发这些值，不需要硬编码。
>
> 样本：`ziyoumao-3.1.0-windows-amd64-setup.exe`
> SHA-256：`df52a7dc7fcf30e19d7266de78e819c59b923581ab5ebabea8c078ac37880398`（33,522,999 B）
> 主要调查记录：`ziyoumao-export/INVESTIGATION-LOG.md`（717 行，含每一轮实验）

---

## 0. 结论速览

| 项 | 结论 |
|---|---|
| 官方客户端 | Flutter/Dart UI + 自编译 mihomo（Clash.Meta）Go 内核 + Rust 提权 helper |
| 血缘 | 官方客户端本身就是 **FlClash 改版**（保留 `FlClash2026@ProfileStorage!` 等常量） |
| 面板 | v2board/Xboard 兼容：登录 → `getSubscribe` → `subscribe_url` |
| 鉴权 | `Authorization: <token>`，**不能加 `Bearer`** |
| 订阅分流 | 只有 UA 以 `freecatencua` 开头才返回真节点密文；其它 UA 全是诱饵 |
| 真节点协议 | 全部 `trojan` over TLS，`skip-cert-verify: true`，`udp: true`，密码 = 账号 UUID |
| 订阅加密 | `base64(AES-128-CBC(PKCS7(base64(YAML))))`，key/iv 是 **16 个 ASCII 字符**，不是 hex 解码 |
| 关键陷阱 | `&flag=clash` 会强制诱饵；普通 Clash UA 也是诱饵；不要在失败时自动降级 |
| 配置形态 | 标准 mihomo YAML：proxies / proxy-groups / rules / dns / tun |
| 账号限制 | 实测 `device_limit=null`、`alive_ip=0`；没有客户端证书/签名/设备绑定 |
| 真正风险 | 账号 + 出口 IP + 流量行为，以及把订阅链接/UUID 泄露给别人 |

---

## 0.1 魔改 FlClash 到底需要什么？

**实现阶段不需要**：

- 你的账号密码；
- 账号 UUID、登录 token、订阅 URL；
- 节点服务器域名、节点密码、节点列表；
- 任何真实订阅响应。

这些要么是账号级凭证，要么由订阅动态下发，硬编码进代码只会有泄露风险，而且换账号就失效。

**实现阶段需要**（本文已全部给出）：

- 面板入口 host 列表；
- 登录 / `getSubscribe` 的路径、表单、Header 规则；
- 订阅 UA 的精确值；
- AES key/iv 和解密流程；
- 解密后 YAML 的结构、占位节点、分组/规则/DNS 的坑；
- 固定测试向量（用假节点/假密码，不需要真实账号）。

**运行阶段才需要**：

- 用户在 FlClash 的登录页输入自己的邮箱/密码；
- 客户端登录成功后拿到 token + subscribe_url，保存在安全存储中；
- 拉订阅、解密、导入 profile；
- token 过期时让用户重新登录。

所以：**账号密码只属于运行时输入，不属于代码/文档/仓库**。如果要做真实节点联调，
用自己的账号在客户端里登录即可，不需要把密码交给写代码的 AI；如果要做自动化测试，
用测试账号或环境变量注入，且不要提交。

---

## 1. 官方客户端结构

### 1.1 安装包

- PE32 (i386)，Inno Setup 6.7.1。
- 安装路径限制：系统盘只允许 `%LOCALAPPDATA%\Programs`。
- 两段 LZMA 数据：`setup-0.bin`、`setup-1.bin`。
- 安装后目录：

```
ziyoumao.exe                 Flutter runner（Dart AOT 在 data/app.so）
ziyoumaoCore.exe             Go 内核（34.9 MB，mihomo 改入口）
ziyoumaoHelperService.exe    Rust/tokio/hyper 提权 helper（TUN/路由）
data/app.so                  Dart AOT（13 MB，业务逻辑/解密）
data/flutter_assets/assets/data/{GEOIP.dat,GEOSITE.dat,GEOIP.metadb,ASN.mmdb}
quickjs_c_bridge.dll / flutter_js_plugin.dll / sqlite3.dll / proxy_plugin.dll
EnableLoopback.exe           UWP 回环豁免
```

### 1.2 FlClash 血缘证据

`app.so` 中可直接搜到：

```
FlClash2026@ProfileStorage!
FlClash2026@CampusNetworkHost!
[fl_clash/proxy_manager]
```

官方客户端把 FlClash 的 `appName` / `version` 换成了自己的值，但订阅请求的
UA 构造仍然沿用 FlClash 模板：

```
<appName>/v<version> clash-verge Platform/<os>
```

这就是为什么官方 UA 里会同时出现 `freecatencua` 和 `clash-verge`。

### 1.3 内核

`ziyoumaoCore.exe` 的 Go build info：

```
go1.25.0 GOOS=windows GOARCH=amd64 -tags=with_gvisor CGO_ENABLED=0
module: core (devel)
replace github.com/metacubex/mihomo => ./Clash.Meta
```

即：**mihomo（Clash.Meta）** 改了入口，增加 `with_gvisor`（用户态 TUN 栈）。
里面能看到：

```
handleInitClash / handleSetupConfig / handleUpdateConfig / handleValidateConfigBytes
handleStartListener / handleStopListener
handleGetProxies / handleChangeProxy / handleAsyncTestDelay
handleGetConnections / handleGetTraffic / handleGetExternalProviders
handleUpdateGeoData / handleGetCountryCode / handleShutdown
```

### 1.4 进程/IPC/提权

- `ziyoumao.exe` 启动后立刻派生 `ziyoumaoCore.exe <端口号>`。
- 内核用第一个参数作为 **AF_UNIX socket** 地址（不是 TCP 端口）。
- UI 本地 HTTP：`127.0.0.1:49890/start|stop|ping`（另有 `127.0.0.1:9090` 控制器）。
- UI 通过本地 IPC 把配置交给内核，方法名 `getConfigBytes`：

```json
{"method":"getConfigBytes","data":"<base64 明文 YAML>","id":...}
```

- TUN/路由由 `ziyoumaoHelperService.exe` 提权完成；`app.so` 中有
  `runas / ShellExecuteW / elevated / pleaseInputAdminPassword / WindowsHelperServiceStatus`。
- 对 FlClash 适配来说，**不需要复刻这套 IPC/helper**；FlClash 已经自带
  mihomo 内核和 TUN 管理，只需要复刻“拿到明文 YAML”的部分。

---

## 2. 端到端数据流

```
① 远程配置
   https://flmain-1326556767.cos.ap-guangzhou.myqcloud.com/ConFigOss.json   (base64 JSON)
   https://fl-1326556767.cos.ap-shanghai.myqcloud.com/update.json

② 选面板 host（内置 3 个，可自定义）

③ POST {host}/api/v1/passport/auth/login
   form: email, password
   → data.auth_data (JWT) 或 data.token (32 hex)

④ GET {host}/api/v1/user/getSubscribe
   Authorization: <token>       # 裸 token，不能 Bearer
   → data.subscribe_url

⑤ GET {subscribe_url}
   UA: freecatencua/v3.1.0 clash-verge Platform/windows
   Accept: */*
   直连（不能走本地代理）
   → base64 密文

⑥ base64 → AES-128-CBC(key, iv) → 去 PKCS7 → base64 → Clash YAML

⑦ 把 YAML 交给 mihomo（FlClash 用 Profile 导入 / 内核加载）
```

---

## 3. 面板 API 细节

### 3.1 远程配置

`ConFigOss.json` 是 base64 JSON，解码后关键字段：

```json
{
  "Authentication": "自由猫",
  "host_source": "http://自由猫.com",
  "Customer": "https://t.me/FreeCat_Group",
  "InviteLink": "https://us.freecat.cloud/register?code=",
  "hosts": [
    "https://tccdnclient.miaowupaa.com",
    "https://115.159.221.23",
    "https://tuc.skyoutdoors.com.cn"
  ],
  "campusHosts": []
}
```

说明：

- `hosts` 是面板入口列表；客户端可以按顺序试，也可以让用户填自定义 host。
- `Authentication` / `host_source` 是中文/展示字段，**不要原样塞进 HTTP 头**
  （latin-1 不合法）；实测也没有校验作用。
- `update.json` 用于客户端更新，不是节点来源。

### 3.2 登录

```
POST {host}/api/v1/passport/auth/login
Content-Type: application/x-www-form-urlencoded
User-Agent: ziyoumao/v3.1.0 clash-verge Platform/windows
Accept: application/json

email=<email>&password=<password>
```

成功：

```json
{"data":{"token":"<32 hex>","auth_data":"<JWT>","...":"..."}}
```

- `auth_data` 是 HS256 JWT；`token` 是 32 hex。
- 真正的鉴权值优先取 `auth_data`，没有则取 `token`。
- 失败通常是 401/422，body 为 JSON `message`。
- 面板对 UA **不敏感**；但建议统一用官方 UA，减少日志差异。

### 3.3 取订阅地址

```
GET {host}/api/v1/user/getSubscribe
Authorization: <token>          # 裸 token！Bearer 会 403
User-Agent: ziyoumao/v3.1.0 clash-verge Platform/windows
Accept: application/json
```

返回：

```json
{"data":{"subscribe_url":"https://<sub-host>/api/v1/client/subscribe?token=<token>", "...":"..."}}
```

- 有的实现字段名是 `subscribeUrl`，两个都要兼容。
- 这个 URL 直接包含订阅 token，**等同账号凭证**。
- token 失效时返回 403「未登录或登陆已过期」，需要重新登录。
- 实测面板没有设备绑定/设备数限制；`device_limit=null`、`alive_ip=0`。

### 3.4 账号信息（可选 UI）

`getSubscribe` 的 `data` 里还包含：

```
email
plan.name / plan_id
transfer_enable     # 总流量，字节
u / d               # 已上传/下载，字节
expired_at          # null / 空 => 长期有效
device_limit
alive_ip
```

`whoami` 的换算：`used = u + d`，`total = transfer_enable`，单位字节。

### 3.5 其它已知端点

```
/api/v1/passport/auth/login        /register /forget
/api/v1/passport/comm/sendEmailVerify
/api/v1/guest/comm/config          /api/v1/user/comm/config
/api/v1/user/getSubscribe          /api/v1/user/info
/api/v1/user/changePassword        /api/v1/user/plan/fetch2
/api/v1/user/order/fetch           /api/v1/user/order/save2
/api/v1/user/notice/fetch          /api/v1/user/ticket/fetch /reply /close
/api/v1/user/invite/fetch          /details /save
/api/v1/user/getStat               /api/v1/user/redeemgiftcard
/api/v1/user/transfer              /api/v1/user/stat/getTrafficLog
```

FlClash 适配最小集：`login` + `getSubscribe`；账号页可选 `plan/transfer/expired`。

---

## 4. 订阅 UA 分流：真节点 vs 诱饵

### 4.1 实测矩阵

| UA | 返回 | 大小 | 内容 |
|---|---|---|---|
| `freecatencua/v3.1.0 clash-verge Platform/windows` | base64 密文 | ~115,116 B | 真节点（需本地解密） |
| `clash-verge/v2.4.2`、`clash/1.18.0`、`FlClash/0.8.80`（任意含 `clash`） | Clash YAML | ~65,616 B | **诱饵**，节点域名 CNAME 到 `google.com` |
| 不含 `clash` 的 UA（curl/mihomo/空） | base64 v2ray 链接 | ~35,752 B | 同一批诱饵域名 |
| 任意 UA + `&flag=clash` | Clash YAML | ~65,616 B | **强制诱饵**（官方 UA 也会被降级） |

**判据是 UA 前缀 `freecatencua`，不是“有没有 clash”。**
Windows 客户端固定发 `Platform/windows`；做跨平台客户端时建议也原样使用这串
（服务端目前只按前缀分流；若未来校验平台，再按实际平台调整并实测）。

### 4.2 诱饵特征

- 节点 `server` 指向 `freevip*.freecatnodles.com`（注意拼写是 `nodles`）。
- 这些域名是 6 条手工 CNAME → `google.com`；随机子域 NXDOMAIN（不是泛解析）。
- 节点端口背后是 Google 前端，TLS 对端 EOF / 证书 `*.google.com`，必然超时。
- YAML 里可能出现 `freecatnodles.com`、`freevip` 字样；检测到直接报错，不要导入。
- `flag=clash` 不是“兼容模式”，只是强制诱饵分支；**绝不要在官方 UA 失败时自动追加**。

### 4.3 已知踩坑

早期 zycat 把官方 UA 猜成 `ziyoumao/...`，一直在诱饵分支；
后来从 Windows 官方客户端拿到真实 `global-ua` 才修正为 `freecatencua/...`。
另有一个反直觉点：FlClash 自己的默认 UA 就是 `clash-verge/v2.4.2`，
所以“原生 FlClash 直接导入订阅”只会拿到诱饵，必须改 UA。

---

## 5. 加密订阅：算法、密钥、检测、恢复

### 5.1 算法

```
HTTP body (base64 文本)
  │ base64 decode
  ▼
ciphertext (16 字节对齐)
  │ AES-128-CBC(key, iv) + PKCS7 去填充
  ▼
inner base64 文本
  │ base64 decode
  ▼
Clash YAML
```

加密方向：

```
YAML → base64 → PKCS7 pad → AES-128-CBC → base64 → HTTP body
```

### 5.2 密钥

```text
key = "efbf326c0a946d3f"   # 16 个 ASCII 字符 = 16 字节
iv  = "ed287033263d145d"   # 16 个 ASCII 字符 = 16 字节
```

**不要 hex decode 这两个字符串！** 直接把 UTF-8/ASCII 字节作为 key/iv。
这是实现时最容易踩的坑。

### 5.3 检测

官方 UA 返回的 body 特征：

- 文本是 base64（可能带换行/空白，先去掉再解码）；
- 解码后长度通常 > 4 KB、`len % 16 == 0`；
- 字节熵接近 8（实测 7.998）；
- 直接当 YAML 解析会失败。

zycat 的 `LooksEncrypted()` 规则：

```
len(trim(body)) >= 4096
&& base64 解码成功
&& len(raw) >= 4096
&& len(raw)%16 == 0
&& Shannon entropy > 7.0
```

**给 FlClash 的建议**：不要依赖熵阈值（小账号/少节点可能误判）。
只要 UA 是官方值，就直接尝试 AES 解密；失败再回退 YAML/报错。

### 5.4 Python 参考实现

```python
import base64
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

KEY = b"efbf326c0a946d3f"
IV  = b"ed287033263d145d"

def decrypt(body: bytes) -> bytes:
    raw = base64.b64decode(body, validate=False)
    dec = Cipher(algorithms.AES(KEY), modes.CBC(IV)).decryptor()
    pt = dec.update(raw) + dec.finalize()
    pad = pt[-1]
    assert 1 <= pad <= 16 and pt[-pad:] == bytes([pad]) * pad
    return base64.b64decode(pt[:-pad])
```

### 5.5 Dart / FlClash 参考实现

```dart
import 'dart:convert';
import 'package:pointycastle/export.dart';

const _key = 'efbf326c0a946d3f';
const _iv  = 'ed287033263d145d';

Uint8List decryptSubscription(String body) {
  final raw = base64.decode(body.replaceAll(RegExp(r'\s'), ''));
  final cipher = PaddedBlockCipherImpl(
    PKCS7Padding(),
    CBCBlockCipher(AESEngine()),
  );
  cipher.init(
    false,
    PaddedBlockCipherParameters(
      ParametersWithIV(
        KeyParameter(utf8.encode(_key)),
        utf8.encode(_iv),
      ),
      null,
    ),
  );
  final plain = cipher.process(raw);
  return base64.decode(utf8.decode(plain));
}
```

### 5.6 固定测试向量（可用于单元测试）

输入 YAML（可保存为 `fixture.yaml`）：

```yaml
mixed-port: 7890
proxies:
  - { name: 'A', type: trojan, server: 203.0.113.10, port: 443, password: test, udp: true, sni: example.com, skip-cert-verify: true }
proxy-groups:
  - { name: 'Freecat', type: select, proxies: ['A'] }
rules:
  - 'MATCH,Freecat'
```

YAML SHA-256：

```text
4a621e84f860996dc4f314e6beb273b85e0c125ad3582fccd8689c05f11543be
```

对应的订阅 body（472 字符，用上面的 key/iv 生成，可直接作为解密测试输入）：

```text
8SlwJWj6g+z7Z91qefKl/j+J49j5bY0ZUFvFF5zd/oBzMRbCPr+/5pBUzRXgnvdBZifo4VrMYc/y6J0w9xmLIwk+iPF4n3EnZF0EnORAnlv40XLMuT/OjxE0EsIVVIm8Rau4FYsX0PpNoSZfUIITE7Cl7a+3ng2IO9T4s1NUyJQBsbfEO3ECeP+9ngA1J2abi1aDdObwYE4QpOkmj59E9pBmfGwtIOPEo8gEEwESPrRhRg/sS0zxeAwmhuFBdAVK9SBgUEsTweavCNQgmZHmniMys2ETcgXDAg4ZhOBJGG89tHfOggGmwvl+WfdbZcaPsIpGa9K+p6Z7dOwvs0PITtWRE1smUAk1/d+MUuqSmcEXObCGrk5EGAicRGVsLUSq9rL1L7MLzBKC97OFWIbpoXFDLBVkJZbFuhk7azTQECWoE/7TbpPIuQIuspju6YzsNZYLVvaG965uxIgjFFUoRg==
```

解密后的 YAML 应逐字节等于上面的 fixture。

### 5.7 密钥轮换 / 兜底

官方如果换版本并换 key/iv，解密会报 PKCS7 错误。兜底顺序：

1. **重抓 AOT**：Dart AOT 中定位 AES 调用点，运行期 hook 取真实 key/iv
   （官方就是用运行时插桩从 `sub_790840` 里 dump 出来的）。
2. **跑官方客户端抓 IPC**：Wine + Xvfb + strace，
   捕获 `getConfigBytes` 的 `data`（base64 明文 YAML），再反推新 key。
   zycat 的 `zycat refresh` 就是这个流程。
3. **本地导入**：把抓到的 YAML 用 `zycat import` / FlClash 导入。

`SubKey` / `SubIV` 在 zycat 里是导出的变量，便于快速替换。

---

## 6. 解密后的 YAML 形态

### 6.1 顶层结构

一份真实的解密结果大致是：

```yaml
mixed-port: 7890
allow-lan: false
bind-address: '*'
mode: rule
log-level: info
external-controller: "127.0.0.1:9090"
secret: "<controller secret>"
dns:
  enable: true
  ipv6: false
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  use-hosts: true
  respect-rules: true
  default-nameserver: [...]
  proxy-server-nameserver: [...]
  nameserver: [...]
  fallback: [1.1.1.1, 8.8.8.8]
  fallback-filter:
    geoip: true
    geoip-code: CN
    geosite: [gfw]
    ipcidr: [240.0.0.0/4]
    domain: [+.google.com, +.facebook.com, +.youtube.com]
proxies:
  - { ... }
proxy-groups:
  - { ... }
rules:
  - ...
```

注意：不同时间/不同账号可能看到 4 个分组，也可能看到 30+ 个地区分组；
规则数在 515～527 之间变化。**不要把分组数量、节点数量写死。**

### 6.2 节点条目

全部是 trojan，字段固定：

```yaml
- name: "🇭🇰 GG香港1-1｜媒体AI"
  type: "trojan"
  server: "<node-domain>"
  port: 29833
  password: "<账号 UUID>"
  udp: true
  sni: "v1.kwaicdn.com"
  skip-cert-verify: true
```

观察到的规律：

- 120 条 = **116 个真实节点 + 4 条信息占位**（账号/时间不同会变）。
- 3 个节点域名 × 46 个端口；同一域名不同端口=不同落地。
- SNI 伪装成 6 个 CDN 域名（`v1.kwaicdn.com`、`g.alicdn.com`、`o.alicdn.com`、
  `p-pc-weboff.byteimg.com`、`bvc.bilivideo.com`、`v6-dy.ixigua.com`）。
- **所有节点共用同一个 password = 账号 UUID**。
- `skip-cert-verify: true`，即节点证书不校验；这是服务端设计，不是客户端 bug。
- 节点名带国旗、线路代码和标签：`媒体AI` / `家宽` / `原生` / `限速` /
  `电信优化` / `电信专用` / `x2` / `x3` / `x5`（倍率）。
- 节点名里的地区不一定等于真实出口：存在中转（例如出口显示 CN，但名字是日本）。

### 6.3 4 条信息占位节点（必须过滤）

名字以这些词开头/包含：

```
剩余流量：<流量>
套餐到期：<日期或“长期有效”>
🏠 网址：【ziyoumao.cloud】
🪧 提示：AI请使用AI名称节点
```

它们也是合法的 trojan 条目（有 server/port/password），但**不是可用节点**。
用途：

- `剩余流量：355.07 GB` → 账号剩余流量；
- `套餐到期：长期有效` → 到期时间；
- 网址/提示 → 广告。

处理要求：

1. 从节点列表 UI 中隐藏/过滤；
2. 从所有 `proxy-groups` 的 `proxies` 成员列表中删除；
3. 不要因为“名字里有 ://”就崩；
4. 不要把它们当测速目标。

### 6.4 分组

当前订阅常见的 4 个分组：

```yaml
- name: "Freecat 🐾自由猫"
  type: select
  proxies: ["自动选择", "故障转移", "<node>", ...]

- name: "自动选择"
  type: url-test
  proxies: ["<node>", ...]
  url: "http://cp.cloudflare.com/generate_204"
  interval: 600

- name: "故障转移"
  type: fallback
  proxies: ["<node>", ...]
  url: "..."
  interval: 600
```

另外可能还有 `GLOBAL`、地区分组（🇭🇰 香港、🇸🇬 新加坡、🇸🇪 瑞典……）。
规则里通常有：

```
MATCH,Freecat 🐾自由猫
```

所以：

- **不要随意重命名 `Freecat 🐾自由猫`**，否则 MATCH 规则失效；
- 如果重命名，必须同步改写所有规则目标；
- `自动选择`/`故障转移` 的成员可能包含信息占位，必须过滤；
- url-test/fallback 的测试 URL 可以本地覆盖（zycat 用
  `http://cp.cloudflare.com/generate_204`，官方/其他版本可能用 gstatic）。

### 6.5 规则

- 约 515～527 条，绝大多数是域名规则：
  `DOMAIN-SUFFIX` / `DOMAIN-KEYWORD` / `DOMAIN` / `IP-CIDR` / `IP-CIDR6` / `GEOIP` / `MATCH`。
- 含一批 **Windows 进程规则**：

  ```
  PROCESS-NAME,WeChat.exe,DIRECT
  PROCESS-NAME,QQ.exe,DIRECT
  PROCESS-NAME,codex.exe,Freecat 🐾自由猫
  PROCESS-NAME,Telegram.exe,Freecat 🐾自由猫
  ```

  在 Linux/Android 上这些规则通常不会匹配；mihomo 能解析，但 FlClash 移动端
  可能没有进程匹配能力。不要因为看到 `.exe` 就丢弃整份规则。
- 有少量 `GEOIP,CN,DIRECT` / `MATCH,Freecat 🐾自由猫`。
- 规则目标必须存在于 proxies/groups 中；导出/改名后要校验。

### 6.6 DNS

订阅自带一套 fake-ip DNS：

- `enhanced-mode: fake-ip`
- `fake-ip-range: 198.18.0.1/16`
- `respect-rules: true`
- `fallback-filter` 使用 `geosite: [gfw]`

这意味着 **需要 `geosite.dat`**（以及 `geoip.dat`/`geoip.metadb`）。
FlClash 如果用自己的 DNS/TUN 覆盖，要避免和这份 DNS 冲突；
如果要保留订阅 DNS，必须确保 geo 数据到位。

### 6.7 `subscription-userinfo` 响应头

订阅响应通常带：

```text
subscription-userinfo: upload=<bytes>; download=<bytes>; total=<bytes>; expire=<unix|空>
profile-update-interval: 24
```

可作为流量/到期/更新周期的辅助来源。

---

## 7. 官方客户端本地行为（与订阅协议无关，但值得知道）

- 官方配置交给内核时是 **明文 YAML**；`getConfigBytes` IPC 可直接截获。
- 官方落盘的 `profiles/999999.yaml` 不是明文，而是：
  `XOR(订阅响应体, "FlClash2026@ProfileStorage!")`（27 字节循环密钥）。
  另一个常量 `FlClash2026@CampusNetworkHost!` 用于校园网，和订阅无关。
- 官方客户端用 FlClash 的存储/配置框架，所以这份 XOR 逻辑对魔改 FlClash
  可能已经有现成实现，不需要重写。
- 官方 TUN 由 helper 提权，配置形态是 mihomo 的 `tun`（auto-route/dns-hijack/stack）。
- 官方内核的控制器端口/secret 由客户端生成；FlClash 用自己的即可。

---

## 8. zycat 已经验证过的落地逻辑

可参考代码：

- `freecat_client/src/internal/panel/panel.go`：登录、getSubscribe、Fetch、Decrypt、LooksEncrypted。
- `freecat_client/src/internal/cfg/tune.go`：Rewrite、Tune、Markers、StripMarkers。
- `freecat_client/src/main.go`：`login/whoami/sub/import/refresh`。
- `ziyoumao-export/decrypt_subscription.py`：最小解密脚本。
- `ziyoumao-export/INVESTIGATION-LOG.md`：完整实验记录。

### 8.1 拉取

```
panel.Login(host, email, password)
  → token = data.auth_data || data.token
panel.Subscribe(host, token)
  → subURL = data.subscribe_url || data.subscribeUrl
panel.Fetch(subURL, officialUA, false, rawPath)
  → 直连、无代理
  → 若 LooksEncrypted 则 Decrypt
```

关键细节：

- 面板/订阅请求都 **不走系统代理**（避免自己套自己）。
- 订阅请求 `Accept: */*`，UA 必须官方值。
- 保存原始响应（`--raw`）便于 key 轮换时对照。
- 诱饵字符串命中就报错，不自动重试 `flag=clash`。

### 8.2 本地改写（zycat 的选择）

`Rewrite` 只改这些顶层键，其他内容（尤其 proxies/rules/dns）原样保留：

```text
mixed-port
allow-lan
bind-address
mode
log-level
ipv6
external-controller
secret
unified-delay
tcp-concurrent
find-process-mode
geodata-mode
geo-auto-update
profile
tun
```

具体值：

```yaml
mixed-port: <port>
allow-lan: <bool>
bind-address: '127.0.0.1' 或 '*'
mode: rule
log-level: info
ipv6: false
external-controller: 127.0.0.1:<ctrl>
secret: '<secret>'
unified-delay: true
tcp-concurrent: true
find-process-mode: off
geodata-mode: false
geo-auto-update: false
profile:
  store-selected: true
  store-fake-ip: true
tun:
  enable: <bool>
  stack: mixed
  dns-hijack:
    - any:53
  auto-route: <bool>
  auto-detect-interface: true
  strict-route: false
```

`Tune`：

- 对 `url-test` / `fallback` 组，把 `url` 改为
  `http://cp.cloudflare.com/generate_204`（可配置），`interval` 改为 600；
- 从 select/url-test/fallback 的成员列表里删除 4 类信息占位；
- 不删除占位 proxy 条目本身（保留给账号页解析），但 UI 隐藏。

这些选择不是协议要求，FlClash 可以按自己的设置覆盖；关键是**不要破坏
proxies/rules/dns，不要把 MATCH 目标改没**。

> zycat 的 `Tune`/`StripMarkers` 是文本级实现，假设分组是
> `- { name: ..., proxies: [...] }` 的 flow style；FlClash 有 YAML 解析器，
> 应该改成结构化处理，不要照搬正则。

### 8.3 运行

- mihomo 启动：`mihomo -d <dir> -f <config>`；
- 启动前清理指向同一 config 的旧 mihomo；
- 环境变量清掉 `http_proxy/https_proxy/all_proxy`，避免回环；
- TUN 需要 root/管理员；FlClash 已自带提权方案。

---

## 9. 给 FlClash 的魔改方案

下面按“最小可行”到“完整体验”排列。

### 9.1 需要新增的模块

1. **Freecat API client**
   - `login(host, email, password)`
   - `getSubscribe(host, token)`
   - `fetchSubscription(url)`（官方 UA、直连）
   - `decryptSubscription(body)`（AES-128-CBC）
2. **Freecat account store**
   - `host / email / token / subscribeUrl / updatedAt`
   - 建议用 FlClash 已有的安全存储；不要明文写日志。
3. **Freecat profile normalization**
   - 过滤 marker 节点；
   - 校验/重写 groups；
   - 保留 DNS/rules；
   - 可选：把主组名/MATCH 目标保持为 `Freecat 🐾自由猫`。
4. **UI**
   - 登录/切换账号；
   - 流量/到期展示；
   - 更新按钮/自动更新；
   - 错误分类：UA错误 / 诱饵 / 解密失败（key轮换）/ token过期。

### 9.2 数据模型建议

```dart
class FreecatAccount {
  String host;
  String email;
  String token;
  String? subscribeUrl;
  DateTime? updatedAt;
}

class FreecatProfile {
  String yaml;
  List<String> markers;
  DateTime fetchedAt;
  String? subscriptionUserinfo;
}
```

### 9.3 登录流程

```
for host in [userHost ?? defaultHosts]:
    try:
        token = login(host, email, password)
        subURL = getSubscribe(host, token)
        save(host, email, token, subURL)
        return
    catch 401/403:
        continue
    catch network:
        continue
raise "所有入口失败"
```

注意：

- 登录表单只要 `email/password`；不要发 deviceId/platform。
- `getSubscribe` 的 `Authorization` 是裸 token。
- 自定义 host 优先；默认 3 个入口只是 fallback。
- token 失效时重新登录，不要拿旧 token 死重试。

### 9.4 拉取 + 解密流程（伪代码）

```dart
Future<String> fetchFreecatProfile(FreecatAccount acc) async {
  final subURL = acc.subscribeUrl ?? await api.getSubscribe(acc.host, acc.token);

  final resp = await directHttp.get(
    subURL,
    headers: {
      'User-Agent': 'freecatencua/v3.1.0 clash-verge Platform/windows',
      'Accept': '*/*',
    },
  );

  if (resp.statusCode != 200) throw FreecatHttpError(resp.statusCode);

  final body = resp.body.trim();

  // 官方 UA 正常情况下一定是密文；不要先按 YAML 判断
  final yamlBytes = try {
    decryptSubscription(body);          // 5.5 的实现
  } on InvalidPadding {
    // key 轮换，或服务端改回明文
    if (looksLikeClashYaml(body)) return body;
    rethrow FreecatKeyRotationError();
  };

  final yaml = utf8.decode(yamlBytes);
  if (yaml.contains('freecatnodles.com') || yaml.contains('freevip')) {
    throw FreecatDecoyError();           // 不应该发生；防御性检查
  }
  return yaml;
}
```

**不要**做的事：

- 不要用 FlClash 默认 UA 拉订阅；
- 不要在失败时加 `&flag=clash`；
- 不要走系统代理/本地 mixed 端口；
- 不要把密文当 YAML 存进 profile；
- 不要把 marker 节点当真实节点；
- 不要因为 UI 显示“节点数”而把 marker 算进去。

### 9.5 Profile 规范化

建议在把 YAML 交给 FlClash 的 profile parser 前做一次纯文本/结构处理：

1. 解析 `proxies`，识别 marker（`剩余流量：`/`套餐到期：`/`网址：`/`提示：`）；
2. 从 `proxy-groups[*].proxies` 中删除 marker 名称；
3. 如果主组存在，保持名称，或同步改 `MATCH` 规则；
4. 检查每个 group/rule 目标存在；
5. 可选：把 url-test/fallback 的 `url`/`interval` 改成 FlClash 自己的设置；
6. **保留 `dns` 段**；如果 FlClash 要覆盖 DNS，明确只覆盖自己需要的字段；
7. 保留 `rules` 中的 `PROCESS-NAME`，不支持的平台交给内核忽略。

### 9.6 FlClash 集成点（概念）

- 新增一个“自由猫”Provider / ProfileSource，和普通 URL 订阅并列；
- 订阅抓取层：自定义 `User-Agent`、`DIRECT`、响应体解密；
- Profile 层：把解密后的 YAML 当作普通 Clash 配置导入；
- 账号层：FlClash 原本没有登录页，需要新增一个简单的账号页；
- 自动更新：按 `profile-update-interval` 或固定 24h 重新执行
  `getSubscribe → fetch → decrypt → import`；
- 节点列表：隐藏 marker；测速时跳过 marker；
- 切换账号：重新登录后覆盖 token/subURL，重建 profile。

端口注意：官方/zycat 的配置模板常用 mixed-port `7890`、controller `9090`，
FlClash 默认也是这两个；同时运行两个客户端时必须改其中一边，避免端口冲突。

如果 FlClash 的内部接口允许“自定义订阅解析器”，优先在解析器层做；
如果只能走 URL 导入，则需要先落盘一个临时解密后的 YAML，再交给原有导入流程。

### 9.7 错误与用户提示

建议区分：

| 现象 | 原因 | 提示 |
|---|---|---|
| 65 KB YAML，节点域名 `freecatnodles` | UA 不对/`flag=clash` | “请使用自由猫官方 UA，普通 Clash UA 会拿到诱饵” |
| base64 但解密 padding 失败 | key/iv 轮换 | “订阅密钥已更新，需要更新客户端” |
| 403 on getSubscribe | token 过期 | “重新登录” |
| 401 on login | 密码错误 | “邮箱或密码错误” |
| 连接全超时 | 节点被限流/维护 | “等 30–60 秒再测速” |
| 只有 4 条“节点” | 误把 marker 当节点 | “过滤信息占位节点” |

### 9.8 测试清单

- [ ] 用测试向量解密成功（5.6）。
- [ ] 官方 UA 拉真实账号 → 密文 → 解密 → `mihomo -t` 通过。
- [ ] 普通 `clash-verge` UA → 识别诱饵并报错，不导入。
- [ ] 官方 UA + `flag=clash` → 识别诱饵。
- [ ] 解密后 116 节点 + 4 marker；marker 不出现在 UI/分组。
- [ ] `MATCH` 目标存在。
- [ ] 切换节点后出口 IP 变化（如可用）。
- [ ] token 过期 → 重新登录。
- [ ] 更新订阅后保留用户选择的节点（`store-selected` 或 FlClash 自身逻辑）。
- [ ] 不把 token/UUID/订阅 URL 写进日志。

---

## 10. 手工验证命令

```bash
# 1) 登录拿 token（不要用 Bearer）
curl -sS -X POST 'https://<panel-host>/api/v1/passport/auth/login' \
  -H 'User-Agent: ziyoumao/v3.1.0 clash-verge Platform/windows' \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  --data-urlencode 'email=<email>' --data-urlencode 'password=<password>'

# 2) 取订阅地址
curl -sS 'https://<panel-host>/api/v1/user/getSubscribe' \
  -H 'Authorization: <token>' \
  -H 'User-Agent: ziyoumao/v3.1.0 clash-verge Platform/windows'

# 3) 官方 UA 拉密文
curl -sS -A 'freecatencua/v3.1.0 clash-verge Platform/windows' \
  '<subscribe_url>' -o sub.b64

# 4) 解密
python3 ziyoumao-export/decrypt_subscription.py sub.b64 out.yaml

# 5) 校验
mihomo -t -f out.yaml

# 6) 诱饵对照（不要导入）
curl -sS -A 'clash-verge/v2.4.2' '<subscribe_url>' | grep -c freecatnodles
```

---

## 11. 风险与红线

1. **节点 password = 账号 UUID**，整份 YAML 等同于账号凭证；不要外发、不要提交仓库。
2. 所有节点 `skip-cert-verify: true`，无法防中间人；不要在其上处理高敏感业务。
3. 服务方明示/实际可能不支持第三方客户端；使用导出/魔改有风控/封号风险。
4. 不要把订阅 URL、token、UUID、节点列表贴到公开 issue/日志。
5. 本文只做协议互操作与个人客户端适配；不要用于绕过服务条款或分发账号。

---

## 12. 证据/文件索引

| 内容 | 路径 |
|---|---|
| 完整调查日志（含 §13 UA 分流、§17 密钥） | `ziyoumao-export/INVESTIGATION-LOG.md` |
| 早期客户端 RE 记录 | `ziyoumao-export/OFFICIAL-CLIENT-RE.md` |
| 真节点验证 | `ziyoumao-export/REAL-NODES-VERIFICATION.md` |
| 检测面分析（部分结论已被 §13/§17 修正） | `ziyoumao-export/DETECTION-RISK.md` |
| 最小解密脚本 | `ziyoumao-export/decrypt_subscription.py` |
| zycat 面板/解密实现 | `freecat_client/src/internal/panel/panel.go` |
| zycat 配置改写/过滤 | `freecat_client/src/internal/cfg/tune.go` |
| zycat 命令入口 | `freecat_client/src/main.go` |
| 官方客户端 IPC 抓取 | `freecat_client/src/refresh.go` |

> `DETECTION-RISK.md` 里“订阅无加密/UA 只决定格式”的早期判断，已被
> `INVESTIGATION-LOG.md` §13–§17 推翻；以本文和 §13/§17 为准。

---

## 13. 一页伪代码总结

```text
login(host,email,password):
  POST /api/v1/passport/auth/login  (form)
  token = data.auth_data ?? data.token        # 裸 token

getSub(host,token):
  GET /api/v1/user/getSubscribe
  Authorization: token                        # no Bearer
  url = data.subscribe_url ?? data.subscribeUrl

fetch(url):
  GET url
  UA = "freecatencua/v3.1.0 clash-verge Platform/windows"
  direct, no proxy
  if decoy markers: error
  if not encrypted and not YAML: error
  return body

decrypt(body):
  raw = b64decode(body)
  pt  = AES-128-CBC(key="efbf326c0a946d3f",
                    iv ="ed287033263d145d", raw, PKCS7)
  yaml = b64decode(pt)

normalize(yaml):
  remove marker proxies from groups
  keep main group name / MATCH
  keep dns/rules
  validate targets
```

把这份 YAML 交给 mihomo/FlClash 的 profile 加载器即可；协议层已经闭环。
