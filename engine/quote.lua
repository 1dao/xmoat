-- engine/quote.lua — daily prices, kept locally and extended from the last day
-- already held.
--
-- Exports: quote_load, quote_refresh, quote_series, quote_status, quote_view,
--          quote_resolve, quote_merge, quote_is_stale, quote_prefetch
--
-- WHY A CACHE AT ALL. Everything technical — moving averages, a chip
-- distribution, a backtest — reads years of daily bars. Fetching those again
-- for every report would be a megabyte per stock per look, which is rude to
-- the data source and unusable on a phone. So a series is fetched once and
-- afterwards only extended: a refresh asks for the days after the last one
-- kept, a few hundred bytes.
--
-- WHY IT CAN STILL REFETCH EVERYTHING. The series is forward-adjusted, so a
-- dividend or a split rewrites every past price in it. That is what the
-- overlap is for: an incremental fetch starts a little before the last day
-- kept, and if a day present in both copies now has a different close, the two
-- halves cannot be spliced and the whole history is fetched again. Without
-- that check a chart would quietly develop a step at the last ex-dividend
-- date, and every indicator reading across it would be wrong.
--
-- An INDEX is the same data under another name: 'idx:000001' is the Shanghai
-- Composite. It is cached the same way, which is what the market review reads.
--
-- TWO SOURCES, and a cache remembers which one filled it.
--   em   Eastmoney's JSON: forward-adjusted by the source, and the only one
--        that carries the turnover rate, which the chip distribution needs.
--        Half a megabyte per stock, and the server starts refusing after a
--        couple of dozen in a row.
--   tdx  the 通达信 protocol (engine/tdx.lua): 14 KB of binary per stock over
--        a connection that stays open, adjusted by us from the ex-rights
--        records, no turnover rate.
-- A watched stock is therefore asked of Eastmoney, and a wide scan of TDX.
-- Asking for a source the cache was not filled with refetches the whole series
-- rather than splicing two of them together.
--
-- WHEN EASTMONEY REFUSES, TDX. Its quote server blocks an address outright
-- for a while — every request cut off in 160 ms, whatever the host or scheme —
-- and a check that runs on such a day would otherwise judge today against
-- last week's bars and say nothing. So an Eastmoney failure is retried on TDX
-- and the cache records that TDX filled it. The price is paid in turnover:
-- no chip distribution until Eastmoney answers again, and then one whole
-- refetch from it, because the next request asks for Eastmoney as before.
-- Not the other way round: a scan that loses TDX would turn into hundreds of
-- Eastmoney requests in a row, which is exactly what gets an address blocked.

local OVERLAP_DAYS = 10          -- calendar days re-fetched to catch adjustment
local FALLBACK = { em = 'tdx' }  -- which source a failed fetch is retried on
local LABEL = { em = '东方财富', tdx = '通达信' }
local DRIFT = 0.002              -- 0.2%: rounding differs, an adjustment does not

local inflight = {}              -- store key -> true while a fetch runs

-- 'idx:000001' is an index, a bare code is a stock. Returns
--   { key, kind, sec = { code, market } }
-- or nil plus a message.
function g_exports.quote_resolve(code)
    local idx = tostring(code or ''):match('^idx:(%d%d%d%d%d%d)$')
    if idx then
        -- Shenzhen's indices are 399xxx and Beijing's 899xxx; everything else
        -- quoted this way (000001, 000300, 000688) is Shanghai's.
        local p3 = idx:sub(1, 3)
        local market = (p3 == '399' or p3 == '899') and 'SZ' or 'SH'
        return { key = 'quote:idx:' .. idx, kind = 'index', sec = { code = idx, market = market } }
    end
    local sec, err = source_em_security(code)
    if not sec then return nil, err end
    return { key = 'quote:' .. sec.code, kind = 'stock', sec = sec }
end

-- The cached series, or nil. Returns nil plus a message only when the file
-- exists and cannot be read — a caller must not then overwrite it.
function g_exports.quote_load(code)
    local t, err = quote_resolve(code)
    if not t then return nil, err end
    return store_load(t.key)
end

-- Splice `fresh` (oldest first) onto `old`. Returns the merged rows and
-- whether the overlap disagreed, which means the adjustment changed and the
-- old rows are no longer comparable with the new ones.
function g_exports.quote_merge(old, fresh)
    local drifted = false
    local by_date = {}
    for _, r in ipairs(old or {}) do by_date[r.date] = r end
    for _, r in ipairs(fresh or {}) do
        local prev = by_date[r.date]
        if prev and prev.close and r.close and prev.close > 0 then
            if math.abs(r.close - prev.close) / prev.close > DRIFT then drifted = true end
        end
        by_date[r.date] = r
    end
    if drifted then return fresh, true end
    local out = {}
    for _, r in pairs(by_date) do out[#out + 1] = r end
    table.sort(out, function(a, b) return a.date < b.date end)
    return out, false
end

-- Whether a cached series should be fetched again.
--
-- Two questions, in this order. First, could anything newer exist at all —
-- engine/calendar.lua answers that from the last bar held and when it was
-- taken, and says no all weekend, all evening and all through a holiday.
-- Only when it might does the age limit decide, because the last bar of a
-- day that is still trading keeps moving.
function g_exports.quote_is_stale(doc, max_age_min)
    if not doc or type(doc.rows) ~= 'table' or #doc.rows == 0 then return true end
    max_age_min = max_age_min or cfg_int('QUOTE_TTL_MIN', 180)
    if max_age_min <= 0 then return true end
    local fetched = doc.fetched_at
    if type(fetched) ~= 'string' then return true end
    if calendar_quiet(doc.last_date, fetched) then return false end
    -- Both sides are util_now_iso, which is UTC: comparing against a local
    -- date here would make a cache look eight hours older or younger than it
    -- is, depending on the machine's timezone.
    local now = util_now_iso()
    local days = util_date_diff_days(fetched:sub(1, 10), now:sub(1, 10))
    if days == nil then return true end
    local function minutes(s)
        local h, m = s:match('T(%d%d):(%d%d)')
        return (tonumber(h) or 0) * 60 + (tonumber(m) or 0)
    end
    local age = days * 24 * 60 + minutes(now) - minutes(fetched)
    return age >= max_age_min
end

-- COROUTINE-ONLY. Fetch the days that are missing and store the result.
-- Returns the document, or nil plus (error code, message).
--
-- opts = { full = true } forces the whole history rather than an extension,
-- opts.source ('em' or 'tdx') picks which source to ask (the default is
-- PRICE_SOURCE; a cache filled by the other one is replaced, not extended),
-- opts.max_days overrides QUOTE_MAX_DAYS — a scan of the whole market
-- keeps a few hundred days per stock rather than five years of them — and
-- opts.fallback = false stays with the source asked for even when it fails.
function g_exports.quote_refresh(code, opts)
    opts = opts or {}
    local t, terr = quote_resolve(code)
    if not t then return nil, 'bad_request', terr end

    if inflight[t.key] then
        sched_wait_until(function() return not inflight[t.key] end, 120000)
        local kept = store_load(t.key)
        if kept then return kept end
        return nil, 'upstream', '并发的行情刷新失败了'
    end
    inflight[t.key] = true
    local ok, doc, ecode, emsg = pcall(function()
        local old, lerr = store_load(t.key)
        if lerr then cfg_log_warn('%s: cached prices unreadable, refetching all: %s', t.key, lerr) end
        local source = opts.source or cfg_get('PRICE_SOURCE', 'em')
        -- An index is asked of Eastmoney: the review only needs the four, and
        -- its series carries the index's name. TDX is the fallback.
        if t.kind == 'index' then source = 'em' end

        -- What a source may extend: the cached rows if it filled them.
        local function held(src)
            if opts.full or not old or (old.source or 'em') ~= src
                or type(old.rows) ~= 'table' then return {} end
            return old.rows
        end
        local function fetch(src, rows)
            local last = rows[#rows] and rows[#rows].date
            if src == 'tdx' then
                -- TDX serves N bars back from the newest, so an extension asks
                -- for the gap plus a little: there is no "since this date" form.
                local want = opts.max_days or cfg_int('QUOTE_MAX_DAYS', 1200)
                if last then
                    local gap = util_date_diff_days(last, util_today()) or 0
                    want = math.min(want, math.max(20, math.floor(gap * 0.75) + OVERLAP_DAYS))
                end
                return source_tdx_fetch_kline(t.sec, want, { index = t.kind == 'index' })
            end
            local from = last and util_date_add_days(last, -OVERLAP_DAYS) or nil
            return source_em_fetch_kline(t.sec, from)
        end

        local rows = held(source)
        local res, err = fetch(source, rows)
        local other = opts.fallback ~= false and FALLBACK[source]
        if not res and other then
            cfg_log_warn('%s: %s refused (%s), trying %s', t.key, source, tostring(err), other)
            local rows2 = held(other)
            local res2, err2 = fetch(other, rows2)
            -- An empty answer from the fallback is not "this stock has no
            -- prices": the source that would know has just failed.
            if res2 and (#res2.rows > 0 or #rows2 > 0) then
                source, rows, res = other, rows2, res2
            else
                err = string.format('%s %s；%s %s', LABEL[source], tostring(err), LABEL[other],
                    res2 and '没有数据' or tostring(err2))
            end
        end
        if not res then return nil, 'upstream', '行情获取失败：' .. tostring(err) end
        if old and (old.source or 'em') ~= source then
            cfg_log_info('%s: source changed to %s, refetching the whole series', t.key, source)
        end
        if #res.rows == 0 and #rows == 0 then
            return nil, 'not_found', tostring(code) .. ' 没有行情数据'
        end

        local merged, drifted = quote_merge(rows, res.rows)
        if drifted then
            -- Forward adjustment changed: everything held is on the old basis.
            cfg_log_info('%s: adjustment changed, refetching the whole series', t.key)
            local all, aerr = fetch(source, {})
            if not all then return nil, 'upstream', '重新抓取全部行情失败：' .. tostring(aerr) end
            merged = all.rows
            res.name = all.name or res.name
        end

        -- Keep the newest QUOTE_MAX_DAYS. Four years covers a 250-day average,
        -- a chip distribution and a backtest over several cycles; the whole
        -- history would be six times that for a stock listed in the nineties.
        local max_days = opts.max_days or cfg_int('QUOTE_MAX_DAYS', 1200)
        if max_days > 0 and #merged > max_days then
            local cut = {}
            for i = #merged - max_days + 1, #merged do cut[#cut + 1] = merged[i] end
            merged = cut
        end

        local doc2 = {
            version = 1,
            code = t.sec.code, kind = t.kind,
            name = res.name or (old and old.name),
            adjust = 'qfq', source = source,
            fetched_at = util_now_iso(),
            first_date = merged[1] and merged[1].date,
            last_date = merged[#merged] and merged[#merged].date,
            rows = util_json_array(merged),
        }
        local sok, swerr = store_save(t.key, doc2)
        if not sok then return nil, 'internal', '保存行情失败：' .. tostring(swerr) end
        cfg_log_info('%s %s prices from %s: %d days to %s%s', t.key, tostring(doc2.name),
            source, #merged, tostring(doc2.last_date), drifted and ' (refetched)' or '')
        return doc2
    end)
    inflight[t.key] = nil
    if not ok then
        cfg_log_error('%s price refresh raised: %s', tostring(code), tostring(doc))
        return nil, 'internal', '刷新行情时出错'
    end
    return doc, ecode, emsg
end

-- COROUTINE-ONLY. The series every other module reads: cached when it is
-- recent enough, fetched or extended when it is not. A fetch that fails while
-- something usable is cached returns the cached copy and logs — a stale close
-- is worth more than no technical section at all — and says so as the second
-- and third values ('stale', why), for a caller that must tell its reader.
--
-- opts = { force = true, max_age_min = n, offline = true }
function g_exports.quote_series(code, opts)
    opts = opts or {}
    local doc, lerr = quote_load(code)
    if lerr then cfg_log_warn('%s', lerr) end
    if opts.offline then return doc end
    if not opts.force and not quote_is_stale(doc, opts.max_age_min) then return doc end
    local fresh, ecode, emsg = quote_refresh(code, opts)
    if fresh then return fresh end
    if doc then
        cfg_log_warn('%s: using the cached prices (%s): %s', tostring(code),
            tostring(doc.last_date), tostring(emsg))
        return doc, 'stale', emsg
    end
    return nil, ecode, emsg
end

-- COROUTINE-ONLY. Fill the cache for many stocks at once.
--
-- The point of the TDX source: several connections, each pulling the next
-- code off one list, so a hundred stocks take the time of a hundred divided
-- by the pool rather than a hundred round trips in a row. Codes that are
-- already cached and fresh cost nothing at all.
--
-- opts = { source, workers, force, max_days, on_progress }
-- max_days is passed through: bars kept per stock, for when the universe is
-- the whole market and five years of every one of them is not worth the disk.
-- Returns { total, fetched, cached, failed = { {code, error} } }.
function g_exports.quote_prefetch(codes, opts)
    opts = opts or {}
    local source = opts.source or cfg_get('PRICE_SOURCE', 'em')
    -- Eastmoney is fetched one at a time whatever the caller asks: parallel
    -- HTTPS is exactly what makes it start refusing.
    -- One worker per connection. The ceiling is the connection pool's own:
    -- more workers than sockets would just queue inside tdx_acquire.
    local workers = source == 'tdx' and math.max(1, math.min(opts.workers
        or cfg_int('TDX_CONNECTIONS', 32), 64)) or 1

    local queue, next_index = {}, 1
    for _, c in ipairs(codes or {}) do queue[#queue + 1] = c end
    local out = { total = #queue, fetched = 0, cached = 0, failed = util_json_array({}) }
    if #queue == 0 then return out end

    local running = 0
    local function work()
        while true do
            local i = next_index
            if i > #queue then break end
            next_index = i + 1
            local code = queue[i]
            local doc = quote_load(code)
            local fresh = doc and (doc.source or 'em') == source and not opts.force
                and not quote_is_stale(doc)
            if fresh then
                out.cached = out.cached + 1
            else
                local got, _, err = quote_refresh(code, { source = source, full = opts.force,
                                                          max_days = opts.max_days })
                if got then
                    out.fetched = out.fetched + 1
                else
                    out.failed[#out.failed + 1] = { code = code, error = tostring(err) }
                end
            end
            if opts.on_progress and (out.fetched + out.cached + #out.failed) % 25 == 0 then
                opts.on_progress(out)
            end
        end
        running = running - 1
    end

    for _ = 1, workers do
        running = running + 1
        sched_spawn('quote prefetch', work)
    end
    -- Each worker runs until the queue is empty; this waits for all of them.
    sched_wait_until(function() return running <= 0 end,
                     cfg_int('PREFETCH_TIMEOUT_MS', 600000))
    cfg_log_info('prefetch: %d cached, %d fetched, %d failed (%s, %d worker(s))',
        out.cached, out.fetched, #out.failed, source, workers)
    return out
end

-- What is cached, without the rows: for a status line and for deciding
-- whether a refresh is worth asking for.
function g_exports.quote_status(code)
    local doc = quote_load(code)
    if not doc then return nil end
    return { code = doc.code, kind = doc.kind, name = doc.name, adjust = doc.adjust,
             source = doc.source or 'em',
             fetched_at = doc.fetched_at, first_date = doc.first_date,
             last_date = doc.last_date, days = #(doc.rows or {}),
             stale = quote_is_stale(doc) }
end

-- The document as a client sees it: the newest `days` rows, or none when days
-- is 0, which is all a status panel needs.
function g_exports.quote_view(doc, days)
    local rows = doc.rows or {}
    local out = {}
    if days and days > 0 then
        for i = math.max(1, #rows - days + 1), #rows do out[#out + 1] = rows[i] end
    end
    return { code = doc.code, kind = doc.kind, name = doc.name, adjust = doc.adjust,
             source = doc.source or 'em',
             fetched_at = doc.fetched_at, first_date = doc.first_date,
             last_date = doc.last_date, days = #rows, rows = util_json_array(out) }
end
