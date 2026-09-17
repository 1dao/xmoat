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
| `internal` | 500 | 程序错误或磁盘错误，详情在日志里 |
| `unauthorized` | 401 | 仅 HTTP：设置了 `API_TOKEN` 但请求没带或带错 |

## HTTP 约定

- 参数合并顺序：JSON 请求体 → 查询字符串 → 路径参数，后者覆盖前者。所以请求体改不了 URL 指定的股票。
- 查询字符串里的数字和布尔值会自动转换；JSON 请求体里的值不做猜测，类型不对就是 `bad_request`。
- `null` 只在标注为 nullable 的参数上有效，表示"清除"。
- 设置了 `API_TOKEN` 时，每个 `/api` 请求都要带 `Authorization: Bearer <token>`。
- 设置了 `CORS_ORIGIN` 时，响应带相应的 CORS 头，`OPTIONS` 预检返回 204。

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

### ValuationSeries

```ts
type ValuationSeries = {
  metric: string, from?: string, to?: string,
  points: [date: string, value: number | null][],   // 超过 max_points 时等间隔抽样，最后一天总是保留
}
```
