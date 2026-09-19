-- engine/levels.lua — a buy range, a stop and a target, computed by rule.
--
-- Exports: levels_metric_for, levels_price_at, levels_build
--
-- WHAT THESE ARE, AND WHAT THEY ARE NOT. Every number here is arithmetic on
-- two things the engine already has: where this stock's own multiple has
-- traded (the valuation anchor) and where the price has found support (the
-- technical anchor). Nothing here knows the future, nothing here is advice,
-- and none of it survives a change in the assumptions — a different percentile
-- is a different set of prices, and every output says which one it used.
--
-- The valuation anchor is a multiple turned into a price:
--
--   price at multiple m = close × m / (the multiple today)
--
-- which holds the denominator — TTM earnings, book value — fixed at what it is
-- today. That is exactly right for "what price would put this stock back at
-- its median PE" and exactly wrong as a forecast: when the next report lands,
-- every one of these prices moves. It is worth saying out loud because it is
-- the assumption people forget.
--
-- The stop is not a valuation number at all. It is the nearest support under
-- the price — a long moving average, the lower edge of the chip distribution,
-- the year's low — with a small buffer below it, because a level everyone can
-- see is a level that gets pierced before it holds. For a long-term holder the
-- honest note is the one in `notes`: what should stop you out is the business
-- getting worse, not the price reaching a number.

-- Per-template default: a bank or an insurer is read on book value, everything
-- else on earnings. PS and PCF are not used as anchors — a price-to-sales
-- band says little about what a share is worth without a margin assumption.
local TEMPLATE_METRIC = { bank = 'pb', insurance = 'pb', broker = 'pb' }

local METRIC_LABEL = {
    pe_ttm = 'PE（TTM）', pb = 'PB（MRQ）', ps_ttm = 'PS（TTM）', pcf_ttm = 'PCF（TTM）',
}

-- Which multiple to anchor on: the band's own metric if the user set one,
-- otherwise the template's.
function g_exports.levels_metric_for(template, band)
    if band and band.metric then return band.metric end
    return TEMPLATE_METRIC[template] or 'pe_ttm'
end

-- The price that would put `metric` at `target`, given today's close and
-- today's value of that metric.
function g_exports.levels_price_at(close, now, target)
    close, now, target = util_num(close), util_num(now), util_num(target)
    if not close or not now or not target or now <= 0 or close <= 0 then return nil end
    return close * target / now
end

-- rows:   the daily valuation series (oldest first)
-- opts: {
--   template, band,                    -- from the stock record and watchlist
--   technical,                         -- the tech_build block, or nil
--   buy_pctl, buy_low_pctl, target_pctl, stop_buffer,
-- }
--
-- Returns the levels block, or nil plus a reason. A reason rather than an
-- empty object: "no levels" is usually "this company is loss-making", which
-- is worth reading.
function g_exports.levels_build(rows, opts)
    opts = opts or {}
    local latest = valuation_latest(rows or {})
    if not latest then return nil, '没有估值数据' end
    local close = util_num(latest.close)
    if not close then return nil, '最新交易日没有收盘价' end

    local metric = levels_metric_for(opts.template, opts.band)
    local now = util_num(latest[metric])
    if not now or now <= 0 then
        return nil, string.format('%s 当前为负或缺失，无法用它作为锚点', METRIC_LABEL[metric] or metric)
    end

    local stats, serr = valuation_percentile(rows, metric, nil)
    if not stats then return nil, serr end

    local buy_pctl = opts.buy_pctl or 25
    local buy_low_pctl = opts.buy_low_pctl or 10
    local target_pctl = opts.target_pctl or 70
    local buffer = (opts.stop_buffer or 3) / 100

    local function q(p)
        return (valuation_quantile(rows, metric, p, nil))
    end

    -- Buy: the user's own band wins over the percentiles, because a band is
    -- them saying what they think the business is worth. The lower edge stays
    -- the 10th percentile so the range has a floor either way.
    local band = opts.band
    local band_low = band and band.metric == metric and util_num(band.low) or nil
    local band_high = band and band.metric == metric and util_num(band.high) or nil

    local buy_metric_high = band_low or q(buy_pctl)
    local buy_metric_low = q(buy_low_pctl)
    local buy_basis
    if band_low then
        -- A band that is already below the cheapest tenth of the history has
        -- no lower edge to offer: the range becomes "at or below this price",
        -- which is what the band actually says.
        if buy_metric_low and buy_metric_low >= band_low then buy_metric_low = nil end
        buy_basis = string.format('%s 到你设置的区间下沿 %s%s', METRIC_LABEL[metric] or metric,
            util_round(band_low, 2),
            buy_metric_low and string.format('，更低处是全历史 %d%% 分位 %s',
                buy_low_pctl, util_round(buy_metric_low, 2)) or '（已低于全历史最低的十分之一）')
    else
        if buy_metric_low and buy_metric_high and buy_metric_low > buy_metric_high then
            buy_metric_low = buy_metric_high
        end
        buy_basis = string.format('%s 回到全历史 %d%%–%d%% 分位', METRIC_LABEL[metric] or metric,
            buy_low_pctl, buy_pctl)
    end
    local target_metric = band_high or q(target_pctl)

    local buy = buy_metric_high and {
        low = levels_price_at(close, now, buy_metric_low),
        high = levels_price_at(close, now, buy_metric_high),
        metric_low = buy_metric_low, metric_high = buy_metric_high,
        basis = buy_basis,
    } or nil

    local target_price = levels_price_at(close, now, target_metric)
    local target = target_price and {
        price = target_price,
        metric_value = target_metric,
        upside = (target_price - close) / close * 100,
        basis = band_high and string.format('%s 到你设置的区间上沿 %s',
                    METRIC_LABEL[metric] or metric, util_round(band_high, 2))
                or string.format('%s 回到全历史 %d%% 分位', METRIC_LABEL[metric] or metric, target_pctl),
    } or nil

    -- Stop: the nearest support strictly below the price. Candidates are named
    -- so the output can say which one it used rather than only the number.
    local t = opts.technical
    local support, support_label
    local function consider(v, label)
        v = util_num(v)
        if not v or v >= close then return end
        if not support or v > support then support, support_label = v, label end
    end
    if t and not t.note then
        consider(t.ma and t.ma['250'], 'MA250')
        consider(t.ma and t.ma['120'], 'MA120')
        consider(t.ma and t.ma['60'], 'MA60')
        consider(t.chips and t.chips.low_90, '筹码 90% 下沿')
        consider(t.range_250 and t.range_250.low, '近 250 日最低')
    end
    local stop
    if support then
        local price = support * (1 - buffer)
        stop = { price = price, support = support, support_label = support_label,
                 buffer = buffer * 100,
                 downside = (price - close) / close * 100,
                 basis = string.format('最近的支撑（%s %s）下方 %s%%', support_label,
                     util_round(support, 2), util_round(buffer * 100, 1)) }
    elseif t and not t.note and t.range_250 and util_num(t.range_250.low) then
        -- Everything is above the price: the year's low is the only level left.
        local low = util_num(t.range_250.low)
        local price = low * (1 - buffer)
        stop = { price = price, support = low, support_label = '近 250 日最低',
                 buffer = buffer * 100,
                 downside = (price - close) / close * 100,
                 basis = string.format('价格已在所有均线之下，只剩近 250 日最低 %s 下方 %s%%',
                     util_round(low, 2), util_round(buffer * 100, 1)) }
    end

    local reward_risk
    if target and stop and close > stop.price then
        reward_risk = (target.price - close) / (close - stop.price)
    end

    local notes = {
        '这些价格是规则算出来的，不是建议：估值锚用的是这只股票自己的历史分位，' ..
        '止损锚用的是价格支撑，换一组分位就是另一组价格。',
        string.format('估值锚把当前的%s固定住了——下一份财报公布后，同样的分位会对应不同的价格。',
            metric == 'pb' and '每股净资产' or '盈利'),
        '对长期持有的人，真正该止损的是基本面变坏，而不是价格跌到某个数字；' ..
        '这里的止损价只是一条机械的风险线。',
    }
    if not stop then notes[#notes + 1] = '没有日线数据，所以没有止损价。' end

    return {
        metric = metric, metric_label = METRIC_LABEL[metric] or metric,
        metric_now = now,
        date = latest.date, close = close,
        source = band_low and 'band' or 'history',
        window = { from = stats.from, to = stats.to, n = stats.n,
                   percentile = stats.percentile, median = stats.median },
        buy = buy, target = target, stop = stop,
        reward_risk = reward_risk,
        notes = util_json_array(notes),
    }
end
