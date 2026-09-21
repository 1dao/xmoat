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
| `system.info` | `GET /api/v1/system/info` | — | 版本、数据源、DCF 假设、检查阈值、交易日历状态 |
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
| `backtest.run` | `GET /api/v1/stocks/:code/backtest` | `signal?`，`percentile?`，`take_profit?`，`stop_loss?`，`horizon?`，`cooldown?`，`offline?` | `Backtest`：方向胜率、止盈止损命中率，以及同窗口的基准 |
| `market.list` | `GET /api/v1/market/list` | `limit?`，`board?`，`industry?`，`keyword?`，`include_st?` | 全市场股票列表（本地快照，不联网） |
| `strategy.prefetch` | `POST /api/v1/strategy/prefetch` | `codes?` / `universe?` / `limit?`，`bars_days?`，`price_source?` | `{total, cached, fetched, failed, ms}`：把一组股票的日线抓到本地 |
| `backtest.sweep` | `GET /api/v1/stocks/:code/backtest/sweep` | `horizon?`，`ma_days?`，`above_pct?`，`flat_max?`，`objective?`，`min_entries?`，`max_worst?` … | `Sweep`：一只股票上的参数网格 |
| `strategy.sweep` | `GET /api/v1/strategy/sweep` | 同上，外加 `codes?` / `universe?` / `limit?` 与筛选条件 | `Sweep`：一组股票合在一起拟合 |
| `strategy.attribute` | `GET /api/v1/strategy/attribute` | 同 scan，外加 `horizon?`，`min_signals?`，`group?` | 按行业/板块/地域分组，每组与自己的基准比 |
| `groups.regions` | `GET /api/v1/groups/regions` | `refresh?`，`offline?` | 地域归属（31 个地域板块，约 5500 只），缓存 30 天 |
| `strategy.scan` | `GET /api/v1/strategy/scan` | `rule?`，`ma_days?` 或 `ma_weeks?`，`flat_lookback?` 或 `flat_weeks?`，`above_pct?`，`flat_max?`，`days?`，`cooldown?`，`record?`，`codes?` / `universe?` / `limit?` | `Scan`：最近 `days` 个交易日里首次突破的股票 |
| `strategy.rules` | `GET /api/v1/strategy/rules` | — | `Rule[]`：内置规则及其参数，默认值来自配置 |
| `signals.list` | `GET /api/v1/signals` | `days?`（默认 30，按信号日），`limit?`（默认 500） | `SignalList`：内置规则的信号记录与之后的涨幅 |
| `signals.run` | `POST /api/v1/signals/run` | — | 按默认参数把全市场跑一遍、记下新发现的并推送；收盘后的检查也做这件事 |
| `review.daily` | `GET /api/v1/review` | `offline?`，`force?`，`top?`（默认 5） | `Review`：大盘、结构、自选三段 |
| `review.sectors` | `GET /api/v1/review/sectors` | `kind?`（industry/concept），`offline?`，`force?` | 板块涨跌表；缓存 `REVIEW_SECTOR_TTL_MIN` 分钟 |
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

type Position = {                           // 持仓；设置后才推送点位与技术面提醒
  shares?: number, cost?: number,           // 都可省：空对象就表示「我持有，细节不填」
  since: string,
}

type WatchEntry = { code: string, added_at: string, note?: string, band?: Band, position?: Position }

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
  levels: Levels,                           // 规则算出的买入/止损/目标；算不出时只有 note
  dividends: Dividends,
  checks: Check[],
  watch?: {
    note?: string, added_at: string, band?: Band,
    position?: Position & {                 // 以下三项由引擎按最新收盘价算出
      profit_pct?: number, profit?: number, market_value?: number,
    },
  },                                        // 不在自选中则缺失
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

### Levels

口径见 [METRICS.md](METRICS.md#点位买入--止损--目标)。**这些不是建议**，是两个锚点的算术：
估值锚（这只股票自己的历史分位，或你设的合理区间）和技术锚（现价下方最近的支撑）。
客户端应当把 `basis` 和 `notes` 一起显示——脱离依据的价格没有意义。

```ts
type Levels = {
  metric: 'pe_ttm' | 'pb' | 'ps_ttm' | 'pcf_ttm',
  metric_label: string, metric_now: number,
  date: string, close: number,
  source: 'band' | 'history',               // 锚是你设的区间，还是历史分位
  window: { from: string, to: string, n: number, percentile: number, median: number },
  buy?: {
    low?: number, high: number,             // low 缺席表示「high 以下」
    metric_low?: number, metric_high: number,
    basis: string,
  },
  target?: { price: number, metric_value: number, upside: number, basis: string },
  stop?: {
    price: number, support: number, support_label: string,
    buffer: number, downside: number, basis: string,
  },
  reward_risk?: number,                     // (目标 − 现价) / (现价 − 止损)
  notes: string[],
  note?: string,                            // 整块算不出时的原因，此时其余字段缺席
}
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

### Backtest

口径见 [METRICS.md](METRICS.md#回测验证)。回放的是引擎自己的规则信号，不是模型的话；
每个信号在每一天只用当天之前的数据判断。`baseline` 是同一段窗口里「随便哪天买」的同样统计，
客户端必须把它和信号的数字并排显示——单独一个胜率是读不出意思的。

```ts
type Backtest = {
  code: string, name?: string, template: Template,
  signal: 'value' | 'trend' | 'value_trend' | 'band',
  signal_note: string,
  metric?: string, percentile?: number,
  entries: number,                          // 触发次数
  tested: number,                           // 可判定的交易日数
  cooldown: number,                         // 两次信号之间的最小间隔（交易日）
  from?: string, to?: string,               // 第一次与最后一次触发
  price_from?: string, price_to?: string,   // 行情缓存覆盖的区间
  horizons: Horizon[],
  barrier: Barrier,
  baseline: { n: number, from?: string, horizons: Horizon[], barrier: Barrier },
  dates: { date: string, close?: number, value?: number, threshold?: number }[],  // 最近 20 次
  notes: string[],
  note?: string,                            // 一次都没触发时的说明，此时统计缺席
}

type Horizon = {
  days: number, n: number,                  // n 是有足够后续数据的次数
  win_rate?: number, avg?: number, median?: number, best?: number, worst?: number,   // 均为 %
}

type Barrier = {
  take_profit: number, stop_loss: number, horizon: number,   // %，%，交易日
  n: number, hit_tp: number, hit_sl: number, neither: number,
  both_same_day: number,                    // 同一天两边都触及，按止损计
  win_rate?: number,                        // hit_tp / (hit_tp + hit_sl)
  tp_rate?: number, sl_rate?: number,       // 占全部信号的比例
  avg_days_tp?: number, avg_days_sl?: number,
}
```

### Sweep 与 Scan

口径见 [METRICS.md](METRICS.md#均线走平后的突破)。`Sweep` 是参数网格，`Scan` 是「现在谁在发信号」。
两者都可以指定股票范围：`codes`（逗号分隔）优先，其次 `universe=screen`（用全市场快照按 `roe_min` 等条件筛），
默认是自选。

```ts
type SweepRow = {
  ma_days: number, above_pct: number, flat_max: number,
  entries: number, stocks?: number,         // stocks 仅多股票拟合：几只股票出过信号
  n: number,                                // 有完整持有期的次数
  win_rate?: number, avg?: number, median?: number, best?: number, worst?: number,  // %
  hit_tp: number, hit_sl: number, barrier_win_rate?: number,
}

type Sweep = {
  code?: string, name?: string,             // 单只股票时
  universe?: 'codes' | 'screen' | 'watchlist', stocks?: number,   // 多只股票时
  signal: 'breakout', signal_note: string,
  from?: string, to?: string, days?: number,
  horizon: number, objective: 'median' | 'avg' | 'win_rate',
  flat_lookback: number, min_day_gain: number, cooldown: number,
  require_: { min_entries: number, min_win_rate?: number, max_worst?: number, max_sl?: number },
  grid: SweepRow[],                         // 整张表，按参数排序
  ranked: SweepRow[],                       // 满足约束的前 10 名
  best?: SweepRow,
  neighbours?: { n: number, mean?: number, worst?: number, cells: SweepRow[] },
  baseline: { n: number, win_rate?: number, avg?: number, median?: number, worst?: number },
  fetch?: { total: number, cached: number, fetched: number, ms?: number, failed: {code, error}[] },
  notes: string[],
}

type MarketList = {
  trade_date: string, fetched_at: string,
  matched: number,                          // 符合条件的总数
  count: number,                            // 这次返回了多少
  rows: { code: string, name: string, industry?: string,
          board: 'main' | 'gem' | 'star' | 'bj' | 'other',
          st?: true, close?: number, market_cap?: number }[],
}

type Rule = {
  id: 'breakout',                           // strategy.scan 的 rule
  title: string, summary: string,
  basis: string,                            // 默认值是怎么来的（网格结论）
  fields: {                                 // 原样作为 strategy.scan 的参数
    name: string, label: string, unit: string,
    default: number,                        // 当前配置；按周说的窗口可能是 8.4 这样的小数
    min: number, max: number, step: number,
  }[],
}

type Scan = {
  universe: string, checked: number, days: number,
  params: { ma_days: number, above_pct: number, flat_max: number,
            flat_lookback: number, min_day_gain: number,
            cooldown: number,                 // 两次信号至少隔几个交易日；默认即只看突破第一天
            ma_weeks: number, flat_weeks: number },   // 同两个窗口，按周（一周 5 个交易日）
  configured: boolean,                      // 参数就是内置默认（只有这样的结果会被记录）
  recorded?: { added: number, pushing?: boolean, note?: string },   // 带 record 且 universe=market 时
  hits: {
    code: string, name?: string, industry?: string,
    date: string, close: number, ma: number, // 信号日（突破第一天）与当天收盘
    above: number,                          // 高出均线 %
    slope: number,                          // 均线在 flat_lookback 内的变动 %
    day_gain?: number, bars_ago: number,    // 距今几个交易日
    last_date: string, last_close: number,  // 最新一根 K 线
    since_pct?: number,                     // 信号日以来涨了多少 %
    pe_ttm?: number, pb?: number, roe?: number, market_cap?: number,
  }[],                                      // 每只股票只留最近的一次
  skipped: { code: string, reason: string }[],
  fetch?: { total: number, cached: number, fetched: number, ms?: number, failed: {code, error}[] },
  note: string,
}
```

`fetch` 里，已经够新的缓存不论是哪个来源填的都算「本地」：扫描用通达信，
也不会把自选股那份带换手率的东方财富日线换掉。

```ts
type SignalList = {
  rule: 'breakout', title: string, days: number,
  total: number, count: number,             // 这段时间里一共几条；这次返回了几条
  daily: boolean,                           // 收盘后的检查会不会自动跑（SIGNALS_DAILY）
  last_run?: { at: string, source: 'daily' | 'web' | 'manual', checked: number,
               found: number, added: number, days: number },
  items: {
    code: string, name?: string, industry?: string,
    signal_date: string, signal_close: number,   // 突破第一天
    added_at: string, added_close: number,       // 记下来的时间，以及当时的最新收盘
    last_date: string, last_close: number,       // 每次扫描顺手更新
    since_signal_pct?: number, since_added_pct?: number,   // 读取时算
    above?: number, day_gain?: number, pe_ttm?: number, pb?: number, roe?: number, market_cap?: number,
    pushed: boolean | 'skipped' | 'failed',
  }[],                                      // 新的在前
}
```

### Review

三段式复盘，口径见 [METRICS.md](METRICS.md#复盘与-regime)。指数来自日线缓存（和个股同一套缓存规则），
板块表单独缓存；`offline=true` 时两者都只读本地。

```ts
type Review = {
  generated_at: string, as_of?: string,     // as_of 是指数最后一个交易日
  market: {
    indexes: {
      code: string, name?: string, date: string,
      close: number, change_pct?: number,
      ma20?: number, ma60?: number, ma250?: number,
      position_250?: number, from_high?: number, volume_ratio?: number,
      error?: string,                       // 这次没取到行情，这一行是缓存里 date 那天的
    }[],
    regime_index: string,
    regime: {
      state: 'bull' | 'bear' | 'range' | 'unknown',
      close?: number, ma20?: number, ma60?: number, ma250?: number,
      ma250_slope?: number,                 // MA250 近 60 个交易日的变化 %
      drawdown?: number, volatility?: number,   // 距 250 日高点 %；近 20 日年化波动 %
      reasons: string[],                    // 这个判断是怎么来的
    },
    stance: { position: string, text: string, note: string },   // 机械映射，不是建议
  },
  structure: {
    fetched_at?: string, source?: string, sector_count?: number,
    breadth?: { up: number, down: number, flat: number, total: number, ratio?: number },
    leaders?: Sector[], laggards?: Sector[],
    note?: string,                          // 没有板块行情时的原因
  },
  watchlist: {
    count: number,
    rows: {
      code: string, name?: string, date?: string,
      close?: number, change_pct?: number,
      percentile?: number,                  // 锚指标的全历史分位
      warnings: number,
      flags: string[],                      // 已进入买入区间 / 跌破止损价 / 达到目标价
    }[],
  },
}

type Sector = {
  code: string, name: string,
  index?: number, change_pct?: number,
  up?: number, down?: number,               // 该板块内涨跌家数
  leader?: string, leader_change?: number,
  laggard?: string, laggard_change?: number,
}
```

### Alert、RunResult、ScheduleStatus

```ts
type Alert = {
  id: string,                               // 由股票和变化内容决定，同一变化只记一次
  seq: number,                              // 单调递增，用于 after_seq 轮询
  code: string, name: string,
  kind: 'report' | 'dividend' | 'band' | 'percentile' | 'check' | 'level' | 'trend',
  // level 与 trend 只对登记了持仓的股票产生
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
  source: 'em' | 'tdx',                     // 这份缓存是谁填的，见 METRICS
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
  problems: {                               // 这次检查没取到的数据，也会写进推送
    kind: 'refresh'                         // 这只自选股整个刷新失败
        | 'prices'                          // 刷新了，但两个行情源都没给出日线
        | 'index'                           // 复盘里的这个指数用的是缓存
        | 'review'                          // 复盘没有生成
        | 'signals',                        // 内置规则没有运行
    code?: string, name?: string, error: string,
  }[],
  signals?: { checked: number, found: number, added: number, days: number },   // 内置规则这次跑的结果
  push: {
    sent: number, skipped?: boolean, busy?: boolean,
    review?: true,                          // 这条推送里带了收盘复盘
    problems?: true,                        // 这条推送里列了没取到的数据
    signals?: number,                       // 这条推送里带了几只新突破
    channels: PushResult[],
  },
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
