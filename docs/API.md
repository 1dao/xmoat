# xmoat API

界面和引擎之间的契约。Web 页面、命令行和将来的手机客户端都只通过这里描述的命令访问引擎；
客户端不计算任何财务数字，只负责展示。

命令定义在 [engine/commands.lua](../engine/commands.lua)，运行中的服务可以用
`GET /api/v1/system/commands` 取到同一份列表。本文与代码不一致时，以代码为准，并修正本文。

## 三种接入方式

| 方式 | 适用 | 做法 |
|---|---|---|
| HTTP | 桌面、服务器、手机 WebView | `bin/xnet main.lua`，请求 `/api/v1/...` |
| 进程内调用 | 嵌入运行时的原生客户端 | 加载 `engine/manifest.lua` 里的模块，在协程里调用 `api_call(name, params, ctx)` |
| 命令行 | 脚本、排查 | `bin/xnet cli.lua call <命令名> key=value ...` |

三种方式得到的结果信封完全一样。手机端可以把引擎和 `main.lua` 跑在 `127.0.0.1` 上、用 WebView 加载 `web/`，
也可以直接桥接 `api_call`，完全不开端口。

## 结果信封

```json
{ "ok": true,  "data": { } }
{ "ok": false, "error": { "code": "not_fetched", "message": "600519 还没有获取过数据，先刷新" } }
```

客户端按 `error.code` 分支，把 `error.message` 展示给用户。

| code | HTTP | 含义 |
|---|---|---|
| `bad_request` | 400 | 参数缺失或不合法（股票代码格式、区间上下限颠倒等） |
| `not_found` | 404 | 没有这个命令、这只股票没有数据，或不在自选中 |
| `not_fetched` | 404 | 代码有效，但还没刷新过；调用 `stock.refresh` |
| `conflict` | 409 | 已经在自选中 |
| `upstream` | 502 | 数据源失败或返回了无法解析的内容 |
| `unavailable` | 503 | 这个功能需要配置才能用（例如没有配置大模型） |
| `internal` | 500 | 程序错误或磁盘错误，详情在日志里 |
| `unauthorized` | 401 | 仅 HTTP：设置了 `API_TOKEN` 但请求没带或带错 |

## HTTP 约定

- 参数合并顺序：JSON 请求体 → 查询字符串 → 路径参数，后者覆盖前者。所以请求体改不了 URL 指定的股票。
- 查询字符串里的数字和布尔值会自动转换；JSON 请求体里的值不做猜测，类型不对就是 `bad_request`。
- `null` 只在标注为 nullable 的参数上有效，表示"清除"。
- 设置了 `API_TOKEN` 时，每个 `/api` 请求都要带 `Authorization: Bearer <token>`。
- 设置了 `CORS_ORIGIN` 时，响应带相应的 CORS 头，`OPTIONS` 预检返回 204。
- `WECOM_CALLBACK_PATH`（默认 `/wecom/callback`）不属于 `/api`，也不走 `API_TOKEN`：企业微信不带 `Authorization`，它的凭证是签名与那把 AES 密钥。配置了 Token 和 EncodingAESKey 才有这条路由；它只回验证串，事件一律读完就丢。

## 命令

| 命令 | HTTP | 参数 | 返回 |
|---|---|---|---|
| `system.info` | `GET /api/v1/system/info` | — | 版本、数据源、DCF 假设、检查阈值 |
| `system.commands` | `GET /api/v1/system/commands` | — | 全部命令及参数 |
| `watchlist.list` | `GET /api/v1/watchlist` | — | `WatchItem[]` |
| `watchlist.add` | `POST /api/v1/watchlist` | `code`，`note?`，`band?` | `WatchEntry`（不会自动抓取） |
| `watchlist.update` | `PATCH /api/v1/watchlist/:code` | `note?`（nullable），`band?`（nullable） | `WatchEntry` |
| `watchlist.remove` | `DELETE /api/v1/watchlist/:code` | — | `{code, removed}`（已抓取的数据保留） |
| `watchlist.refresh` | `POST /api/v1/watchlist/refresh` | — | `[{code, ok, error?}]` |
| `stock.get` | `GET /api/v1/stocks/:code` | — | `Analysis`（读已保存的数据，不联网） |
| `stock.refresh` | `POST /api/v1/stocks/:code/refresh` | — | `Analysis`（先抓取再分析） |
| `stock.valuation` | `GET /api/v1/stocks/:code/valuation` | `metric?`，`years?`，`max_points?` | `ValuationSeries` |
| `stock.reports` | `GET /api/v1/stocks/:code/reports` | `period_type?`，`limit?` | 定期报告主要指标（原始口径） |
| `quote.get` | `GET /api/v1/stocks/:code/quotes` | `days?`（默认 250），`offline?` | `Quotes`；本地缓存够新就直接返回 |
| `quote.refresh` | `POST /api/v1/stocks/:code/quotes/refresh` | `full?` | `Quotes`（不含 rows）；已有缓存时只抓最后一天之后的部分 |
| `alerts.list` | `GET /api/v1/alerts` | `code?`，`limit?`（1–500），`after_seq?` | `Alert[]`，新的在前 |
| `alerts.run` | `POST /api/v1/alerts/run` | — | `RunResult`：刷新全部自选、记录变化并推送，和定时检查相同 |
| `notify.channels` | `GET /api/v1/notify/channels` | — | `{kind, name}[]`，不含任何密钥 |
| `notify.test` | `POST /api/v1/notify/test` | — | `PushResult[]`；没有配置渠道时为 `bad_request` |
| `schedule.status` | `GET /api/v1/schedule` | — | `ScheduleStatus` |
| `market.status` | `GET /api/v1/market` | — | `MarketStatus` |
| `market.refresh` | `POST /api/v1/market/refresh` | — | `MarketStatus`（抓取全市场快照，约 15 次请求） |
| `market.screen` | `GET /api/v1/market/screen` | 见下 | `ScreenResult` |
| `llm.status` | `GET /api/v1/llm` | — | `{enabled, provider?, model?, hint?}`，不含密钥 |
| `insight.get` | `GET /api/v1/stocks/:code/insight` | — | `Insight`（已保存的，不联网）；没有则 `not_found` |
| `insight.generate` | `POST /api/v1/stocks/:code/insight` | — | `Insight`（调用大模型，会产生费用） |
| `insight.ask` | `POST /api/v1/stocks/:code/ask` | `question`（≤500 字），`history?` | `{answer, unverified, provider, model, usage}` |

**行情是怎么缓存的。** 日线（前复权）抓一次就留在本地，之后只补最后一天之后的部分：
`quote.get` 先看缓存，够新（`QUOTE_TTL_MIN`，默认 3 小时）就直接返回，不够新才联网补齐，
`offline=true` 则只读缓存。前复权序列会被分红和送转改写，所以增量抓取会多要十天作为重叠段，
重叠的那几天收盘价对不上就说明复权变了，整段重抓。`:code` 也可以是 `idx:000001` 这样的指数。

**提醒是怎么产生的。** 每次刷新一只自选股（手动、`watchlist.refresh`、`alerts.run` 或定时检查），
引擎都会比较刷新前后的数据并记录变化；`stock.refresh` 和 `watchlist.refresh` 在返回后于后台推送，
`alerts.run` 等推送完成再返回。轮询新提醒的客户端可以记住最大的 `seq`，下次带 `after_seq` 调用 `alerts.list`。

`code` 接受 `600519`、`SH600519`、`600519.SH`，只支持 A 股个股。

首次刷新一只股票会拉取全部历史（约 100 期报告、近 9 年每日估值），数据源繁忙时可能要一分钟；
之后的刷新是增量的。

## 数据结构

以下用 TypeScript 记法描述；`?` 表示可能缺失，`| null` 表示可能是 JSON null。
数字一律是原始值：百分比字段写 `15.2` 表示 15.2%，金额单位是元。

### WatchEntry / WatchItem

```ts
type Band = { metric: 'pe_ttm' | 'pb' | 'ps_ttm' | 'pcf_ttm', low?: number, high?: number }

type WatchEntry = { code: string, added_at: string, note?: string, band?: Band }

type WatchItem = WatchEntry & {
  summary?: {                 // 缺失表示还没抓取过
    name: string, industry?: string, template: Template,
    fetched_at: string, latest_report?: LatestReport,
    date?: string, close?: number, market_cap?: number,
    dividend_yield?: number,  // 近 12 个月，%
    pe_ttm?: { value?: number, percentile_all?: number, percentile_y5?: number },
    pb?:     { value?: number, percentile_all?: number, percentile_y5?: number },
    band?: BandResult,
    warnings: number,         // 检查清单里 warn 的个数
  }
}
```

### Analysis

`schema` 在已有字段含义改变时加一；只增加字段不改 `schema`。

```ts
type Template = 'general' | 'bank' | 'insurance' | 'broker' | 'other'

type Analysis = {
  schema: 1,
  code: string, market: 'SH' | 'SZ' | 'BJ', name: string, industry?: string,
  template: Template,
  fetched_at: string,                       // ISO 8601 UTC
  latest_report?: LatestReport,
  valuation?: Valuation,
  quality: Quality,
  business?: Business,
  technical?: Technical,                     // 有日线缓存时才有；没有缓存就整块缺席
  dividends: Dividends,
  checks: Check[],
  watch?: { note?: string, added_at: string, band?: Band },   // 不在自选中则缺失
  notes: string[],                          // 需要展示给用户的说明，如模板限制
  sources: { name: string, dataset: string, item: string, fetched_at: string }[],
}

type LatestReport = { period: string, period_type: 'Q1' | 'H1' | 'Q3' | 'FY', name?: string, notice_date?: string }
```

### Valuation

```ts
type Valuation = {
  date: string, close: number, market_cap?: number, shares?: number,
  metrics: {
    key: 'pe_ttm' | 'pb' | 'ps_ttm' | 'pcf_ttm', label: string, value?: number,
    all?: Percentile, all_note?: string,    // 全部历史；算不出时 note 说明原因
    y5?: Percentile,  y5_note?: string,     // 近 5 年
  }[],
  extras: {                                 // 没有每日历史、因而没有分位的指标
    key: string, label: string, value: number,
    basis: string, note?: string,
  }[],                                      // 目前只有保险公司的 P/EV
  dividend: {
    dps_ttm: number, yield_ttm?: number,    // 按除息日统计的近 12 个月
    from: string, to: string,
    events: { ex_date: string, dps: number, period: string }[],
  },
  reverse_dcf: {
    implied_growth: number,                 // %
    bound?: 'below' | 'above',              // 超出求解范围 -50%..100%
    discount_rate: number, terminal_growth: number, years: number,
    earnings: number, market_cap: number,
    earnings_label: string, earnings_basis: string, note: string,
  } | { error: string },
  band?: BandResult,
}

type Percentile = { percentile: number, n: number, from: string, to: string, min: number, median: number, max: number }

type BandResult = { metric: string, low?: number, high?: number, value: number, position: 'below' | 'inside' | 'above' }
```

### Technical

口径见 [METRICS.md](METRICS.md#技术面)。整块来自本地日线缓存（`quote.*`），
所以一只从未抓过行情的股票没有这一块；抓到的天数不够（少于 20 个交易日）时只有 `note`。

```ts
type Technical = {
  as_of: string,                            // 最后一个交易日
  fetched_at?: string,                      // 这份行情缓存是什么时候抓的
  days: number,                             // 参与计算的交易日数
  close: number, change_pct?: number,
  ma: { [period: string]: number },         // '5' | '10' | '20' | '60' | '120' | '250'
  bias: { [period: string]: number },       // '6' | '12' | '24' | '60'，%
  trend: {
    alignment: 'bull' | 'bear' | 'none',    // 多头排列 / 空头排列 / 未形成
    above_ma: number, ma_count: number,     // 收盘价站上了几条 / 一共有几条
  },
  range_250: Range, range_60: Range,
  volume_ratio?: number,                    // 5 日均量 / 60 日均量
  chips?: {                                 // 筹码分布，估算模型
    days: number, decay: number,
    avg_cost: number, profit_ratio?: number,          // 平均成本；获利比例 %
    low_90: number, high_90: number, concentration_90?: number,
    low_70: number, high_70: number, concentration_70?: number,
  },
  chips_note?: string,                      // 算不出筹码时的原因（如指数没有换手率）
  note?: string,                            // 整块算不出时的原因
}

type Range = {
  days: number, high: number, low: number,
  position?: number,                        // 收盘价在区间里的百分位，0 最低 100 最高
  from_high?: number,                       // 相对最高价的涨跌幅 %，负数是离高点的距离
}
```

### Quality

```ts
type Quality = {
  template: Template,
  periods: string[],                        // 年报报告期，旧 → 新，最多 10 个
  notice_dates: (string | null)[],
  series: { key: string, label: string, unit: Unit, digits?: number, values: (number | null)[] }[],  // 与 periods 对齐
  summary: { key: string, label: string, unit: Unit, digits?: number, value?: number, basis?: string }[],
}
// digits：展示时建议保留的小数位（如不良率为 2），缺失时由客户端按单位决定
type Unit = '%' | 'pt' | 'x' | 'CNY'
```

### Business

```ts
type Segment = {
  name: string, revenue?: number,
  revenue_share?: number,                   // 占主营收入的百分比
  gross_margin?: number,
  share_change?: number,                    // 相对上一年的百分点变化，由引擎计算
}

type Business = {
  scope?: string,                           // 工商登记的经营范围
  period?: string,                          // 取最近一个年报；中报口径有季节性，不用
  previous_period?: string,                 // 占比变化的对比期
  by: { product: Segment[], region: Segment[], industry: Segment[] },
  review?: { period: string, chars: number },   // 管理层经营评述的元信息，正文不在分析对象里
  reviews: string[],                        // 已保存的经营评述报告期
}
```

### Dividends 与 Check

```ts
type Dividends = {
  consecutive_years: number,                // 从最近一个年报年度往回数
  latest_fy?: number,
  years: { year: number, dps: number, eps?: number, payout_ratio?: number }[],   // 新 → 旧
  pending: { period: string, progress?: string, plan?: string, dps: number }[],  // 已宣布未除息
}

type Check = {
  key: string, title: string,
  status: 'pass' | 'warn' | 'na',           // na = 数据不足，不等于通过
  detail: string,                           // 带数字和报告期的一句话
  value?: number, values?: object, threshold?: number, period?: string,
}
```

### Alert、RunResult、ScheduleStatus

```ts
type Alert = {
  id: string,                               // 由股票和变化内容决定，同一变化只记一次
  seq: number,                              // 单调递增，用于 after_seq 轮询
  code: string, name: string,
  kind: 'report' | 'dividend' | 'band' | 'percentile' | 'check',
  title: string, detail: string,
  status?: 'pass' | 'warn',                 // 仅 check：变成了什么
  period?: string, date?: string,           // 报告期；公告日或估值日期
  created_at: string,
  pushed: true | false | 'skipped' | 'failed',   // skipped = 当时没有配置渠道
  pushed_at?: string, push_attempts?: number,
}

type Quotes = {                             // 日线，前复权
  code: string, kind: 'stock' | 'index', name: string,
  adjust: 'qfq',
  fetched_at: string,                       // 这份缓存是什么时候抓的
  first_date: string, last_date: string,    // 缓存覆盖的区间
  days: number,                             // 缓存里一共多少个交易日
  rows: {
    date: string,
    open: number, high: number, low: number, close: number,
    volume: number,                         // 手
    amount: number,                         // 元
    change_pct: number,                     // %
    turnover: number,                       // 换手率 %
  }[],                                      // 由旧到新，只含请求的 days 条
}

type PushResult = {
  kind: 'wecom' | 'wecom_app' | 'feishu' | 'dingtalk' | 'telegram' | 'webhook',
  name: string, ok: boolean, error?: string,
}

type RunResult = {
  refreshed: { code: string, ok: boolean, error?: { code: string, message: string } }[],
  new_events: number,
  push: { sent: number, skipped?: boolean, busy?: boolean, channels: PushResult[] },
}

type ScheduleStatus = {
  enabled: boolean,                         // 只有 HTTP 宿主会启动定时检查
  running: boolean, last_started?: string,
  times?: string[], weekdays?: string, utc_offset?: number,
  now?: string, next_run?: string,          // 均为 utc_offset 时区的 'YYYY-MM-DD HH:MM'
  last_runs?: { [time: string]: string },
  error?: string,                           // 配置有误时
}
```

推送给 Webhook 渠道的请求体是 `{ source: 'xmoat', title, text, markdown, events: Alert[] }`。

### MarketStatus 与 ScreenResult

全市场快照是两张表按代码合并：当日估值（PE、PB、PS、PCF、市值、收盘价）和最近一个**年报**的业绩
（ROE、营收、净利润及同比、毛利率、每股经营现金流）。用年报而不是最近一期，是为了让所有公司可比。

```ts
type MarketStatus = {
  ready: boolean, refreshing: boolean,
  trade_date?: string, report_period?: string, fetched_at?: string,
  total?: number,          // 快照里的股票数
  with_reports?: number,   // 其中有业绩数据的
  hint?: string,           // ready 为 false 时的说明
}

type ScreenResult = {
  snapshot: MarketStatus, matched: number,   // 符合条件的总数（不受 limit 限制）
  sort: string, order: 'asc' | 'desc',
  rows: {
    code: string, name: string, industry?: string,
    board: 'main' | 'gem' | 'star' | 'bj' | 'other', st?: true,
    close?: number, market_cap?: number,
    pe_ttm?: number, pb?: number, ps_ttm?: number, pcf_ttm?: number,
    roe?: number, revenue?: number, revenue_yoy?: number,
    np_parent?: number, np_parent_yoy?: number, gross_margin?: number,
    eps?: number, ocfps?: number, ocf_to_eps?: number,   // 每股经营现金流 / 每股收益
    notice_date?: string,
  }[],
}
```

`market.screen` 的条件全部可选：`roe_min`、`roe_max`、`pe_min`、`pe_max`、`pb_max`、`ps_max`、
`cap_min`、`cap_max`（亿元）、`revenue_yoy_min`、`np_yoy_min`、`gross_margin_min`、`ocf_to_eps_min`、
`industry`（行业名包含）、`keyword`（名称或代码包含）、`boards`（逗号分隔：main、gem、star、bj）、
`include_st`、`sort`、`order`、`limit`（默认 50，最多 500）。

两点约定：**缺这个数据的股票不会通过针对它的条件**（没有 ROE 的公司不会出现在"ROE ≥ 15%"的结果里）；
**设了 `pe_max` 会自动排除亏损股**，否则负的 PE 会低于任何上限。

### Insight

大模型解读。`result` 是解析后的结构；模型没按格式回答时 `result` 缺失、`raw` 是原文。
`unverified` 是回答里出现、但没能在提供给模型的事实中找到的数字，客户端必须显示这个提示。

```ts
type Insight = {
  code: string, name?: string,
  created_at: string,
  provider: string, model: string,
  usage?: { input_tokens?: number, output_tokens?: number },
  report_period?: string, review_period?: string, valuation_date?: string,
  result?: {
    summary: string,
    moat: { sources: string[], strength: '强' | '中' | '弱' | '无法判断', evidence: string[] },
    changes: string[], risks: string[], questions: string[],
  },
  raw?: string, parse_error?: string,
  unverified: string[],
}
```

### ValuationSeries

```ts
type ValuationSeries = {
  metric: string, from?: string, to?: string,
  points: [date: string, value: number | null][],   // 超过 max_points 时等间隔抽样，最后一天总是保留
}
```
