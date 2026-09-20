-- engine/source_tdx.lua — 通达信 as a price source, forward-adjusted here.
--
-- Exports: source_tdx_adjust, source_tdx_fetch_kline
--
-- It produces the same records as source_em_fetch_kline, so engine/quote.lua
-- does not care which one filled a cache: { code, name, rows = { date, open,
-- high, low, close, volume, amount, change_pct } }, oldest first.
--
-- WHAT IS MISSING, and it matters: a TDX daily bar carries no turnover rate.
-- The chip distribution is built out of turnover, so a series fetched this way
-- has no chips. That is why a watched stock is still filled from Eastmoney,
-- and this source is for the wide scans, where the open, high, low and close
-- are the whole question.
--
-- THE ADJUSTMENT. TDX serves raw prices and the ex-rights records separately,
-- so the forward adjustment happens here, with the formula every Chinese data
-- vendor uses — everything per ten shares, as the announcements state it:
--
--   price_before = (price − bonus/10 + rights_price × rights/10)
--                  ÷ (1 + (shares + rights)/10)
--
-- applied to every bar dated before that ex-date, newest event first so the
-- effects compound the way they actually did. Volume is left as traded: a
-- share count is not a price, and every tool leaves it alone.

-- rows: raw bars, oldest first. events: tdx_parse_xdxr output, oldest first.
-- Returns a NEW list of adjusted rows; the input is not touched. Pure.
function g_exports.source_tdx_adjust(rows, events)
    local out = {}
    for i, r in ipairs(rows or {}) do
        out[i] = { date = r.date, open = r.open, high = r.high, low = r.low,
                   close = r.close, volume = r.volume, amount = r.amount }
    end
    for i = #(events or {}), 1, -1 do
        local e = events[i]
        local bonus = util_num(e.bonus) or 0
        local rights = util_num(e.rights) or 0
        local rights_price = util_num(e.rights_price) or 0
        local shares = util_num(e.shares) or 0
        local divisor = 1 + (shares + rights) / 10
        local offset = bonus / 10 - rights_price * rights / 10
        -- Nothing happened to the share, or the record is nonsense: skip it
        -- rather than divide by something that would bend every earlier price.
        if divisor > 0 and (math.abs(offset) > 1e-9 or math.abs(divisor - 1) > 1e-9) then
            for _, r in ipairs(out) do
                if r.date < e.date then
                    r.open = (r.open - offset) / divisor
                    r.high = (r.high - offset) / divisor
                    r.low = (r.low - offset) / divisor
                    r.close = (r.close - offset) / divisor
                end
            end
        end
    end
    -- The daily change, from the adjusted closes: across an ex-dividend day
    -- that is the change a holder actually felt, which is the point of
    -- adjusting at all.
    for i = 2, #out do
        local prev, cur = out[i - 1].close, out[i].close
        if prev and cur and prev > 0 then out[i].change_pct = (cur / prev - 1) * 100 end
    end
    return out
end

-- COROUTINE-ONLY. `count` daily bars, forward-adjusted, oldest first.
-- Returns { code, rows } or nil plus a message.
function g_exports.source_tdx_fetch_kline(sec, count)
    local code = type(sec) == 'table' and sec.code or tostring(sec)
    local raw, err = tdx_bars(code, count or 800)
    if not raw then return nil, tostring(err) end
    if #raw == 0 then return { code = code, rows = {} } end

    -- The ex-rights records are a second small request. Without them the
    -- prices are still prices — they are simply unadjusted — so a failure
    -- here is logged and the bars are kept.
    local events, xerr = tdx_xdxr(code)
    if not events then
        cfg_log_warn('tdx %s: ex-rights records unavailable (%s), prices left unadjusted',
            code, tostring(xerr))
        events = {}
    end
    return { code = code, rows = source_tdx_adjust(raw, events),
             adjusted = #events > 0 or nil }
end
