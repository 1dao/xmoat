-- engine/calendar.lua — when there could be new daily data, and when there
-- could not.
--
-- Exports: calendar_close_at, calendar_next_weekday, calendar_next_data_at,
--          calendar_quiet, calendar_trading_days, calendar_is_trading_day,
--          calendar_last_trading_day, calendar_status
--
-- THE PROBLEM. Every cache in here — prices, the board table, the market
-- snapshot — decides whether to fetch by asking "how old is this". On a
-- Saturday that is the wrong question: the data is old and there is nothing
-- newer to get. A three-hour age limit spends four requests a day on a
-- weekend, and eight over a public holiday, to be told the same thing.
--
-- NO HOLIDAY TABLE. A list of Chinese public holidays would be right for a
-- year and wrong afterwards, and nobody remembers to update it. Instead:
--
--   * a daily bar for day D can only exist after D's close, so nothing new
--     can appear before the next close after the last bar held;
--   * weekends are certain, so they are skipped outright;
--   * a holiday is discovered rather than declared — the first check after
--     that day's close finds no new bar, and that answer itself moves the next
--     check to the following day. A week-long holiday costs one request.
--
-- The calendar of days that DID trade is not a guess at all: it is the dates
-- in the cached index series, which is a record of exactly the days the
-- exchange was open.

-- 15:00 Beijing is the close; the quote server needs a few minutes more to
-- settle the day's bar.
local CLOSE_HM_MIN = 15 * 60 + 10

local EPOCH = '2000-01-01'

-- An ISO timestamp (or a plain date) as minutes since EPOCH, in UTC.
local function minutes_of(iso)
    if type(iso) ~= 'string' then return nil end
    local date = iso:sub(1, 10)
    local days = util_date_diff_days(EPOCH, date)
    if not days then return nil end
    local h, m = iso:match('T(%d%d):(%d%d)')
    return days * 1440 + (tonumber(h) or 0) * 60 + (tonumber(m) or 0)
end

-- The moment `date`'s bar is final, in UTC minutes since EPOCH. The market's
-- clock is Beijing's whatever the machine is set to, which is the same offset
-- the scheduler uses.
function g_exports.calendar_close_at(date)
    local days = util_date_diff_days(EPOCH, date)
    if not days then return nil end
    local offset = cfg_num('SCHEDULE_UTC_OFFSET', 8)
    return days * 1440 + CLOSE_HM_MIN - math.floor(offset * 60)
end

-- Monday to Friday. The exchange is certainly shut at the weekend; whether it
-- is open on a given weekday is not something this can know.
--
-- The weekday comes from the C library rather than arithmetic on a day count,
-- which is one off-by-one waiting to happen. Noon avoids every daylight-saving
-- edge, as util's own date handling does.
local function is_weekend(date)
    local y, m, d = tostring(date or ''):match('^(%d%d%d%d)%-(%d%d)%-(%d%d)')
    if not y then return false end
    local t = os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 })
    local wday = tonumber(os.date('%w', t))     -- 0 = Sunday
    return wday == 0 or wday == 6
end

function g_exports.calendar_next_weekday(date)
    local d = util_date_add_days(date, 1)
    for _ = 1, 7 do
        if not d then return nil end
        if not is_weekend(d) then return d end
        d = util_date_add_days(d, 1)
    end
    return d
end

-- The earliest moment a bar newer than `last_date` could exist, as UTC minutes
-- since EPOCH. `fetched_at` is when the cache last asked: a check made after a
-- close that produced no new bar is how a holiday is discovered, and it moves
-- the answer on to the next day.
--
-- Returns nil when it cannot tell (no last_date), which means "use the plain
-- age limit".
function g_exports.calendar_next_data_at(last_date, fetched_at)
    if type(last_date) ~= 'string' or #last_date < 10 then return nil end
    local asked = minutes_of(fetched_at)
    local day = calendar_next_weekday(last_date)
    local at = day and calendar_close_at(day)
    if not at then return nil end
    -- Already looked after that close and came back with the same last day:
    -- that day did not trade, so the next chance is the day after it.
    local guard = 0
    while asked and asked >= at and guard < 12 do
        day = calendar_next_weekday(day)
        at = day and calendar_close_at(day)
        if not at then return nil end
        guard = guard + 1
    end
    return at, day
end

-- Whether nothing new can exist yet for a cache whose newest day is
-- `last_date` and which was last fetched at `fetched_at`. `now` defaults to
-- the clock and is an argument so the rule can be tested.
--
-- The one case this deliberately does not claim: a bar dated today, before
-- today's close. It is still moving, so the age limit decides.
function g_exports.calendar_quiet(last_date, fetched_at, now)
    now = now or util_now_iso()
    local now_min = minutes_of(now)
    if not now_min then return false end
    local asked = minutes_of(fetched_at)
    local close_of_last = (type(last_date) == 'string' and #last_date >= 10)
        and calendar_close_at(last_date) or nil
    if close_of_last then
        -- That day is still trading: its bar moves, so the age limit decides.
        if now_min < close_of_last then return false end
        -- We took that bar before its own close, so what is held is a
        -- mid-session snapshot. The settled one is worth one more request.
        if asked and asked < close_of_last then return false end
    end
    local at = calendar_next_data_at(last_date, fetched_at)
    if not at then return false end
    return now_min < at
end

-- The days the exchange was actually open, read off the cached index series.
-- Cached in the module and rebuilt when that series grows.
local days_cache = nil

function g_exports.calendar_trading_days()
    local code = cfg_get('REVIEW_REGIME_INDEX', '000300')
    local doc = quote_load('idx:' .. code)
    if not doc or type(doc.rows) ~= 'table' or #doc.rows == 0 then
        -- The Shanghai Composite is the one most likely to be cached.
        doc = quote_load('idx:000001')
    end
    if not doc or type(doc.rows) ~= 'table' or #doc.rows == 0 then return nil end
    if days_cache and days_cache.to == doc.last_date and days_cache.n == #doc.rows then
        return days_cache
    end
    local set, list = {}, {}
    for _, r in ipairs(doc.rows) do
        if r.date then set[r.date] = true; list[#list + 1] = r.date end
    end
    days_cache = { set = set, list = list, n = #doc.rows,
                   from = list[1], to = list[#list], source = doc.code }
    return days_cache
end

-- true / false for a day inside the known range, nil beyond it — an honest
-- "I do not know" rather than a weekday guess dressed up as a calendar.
function g_exports.calendar_is_trading_day(date)
    local days = calendar_trading_days()
    if not days or not date then return nil end
    if date < days.from or date > days.to then return nil end
    return days.set[date] == true
end

function g_exports.calendar_last_trading_day()
    local days = calendar_trading_days()
    return days and days.to or nil
end

-- For system.info: what the calendar knows and what it concludes.
function g_exports.calendar_status()
    local days = calendar_trading_days()
    if not days then
        return { known = false, note = '还没有缓存指数日线，交易日历为空（复盘或行情抓取一次即可）' }
    end
    local _, day = calendar_next_data_at(days.to, nil)
    return {
        known = true, source = days.source,
        from = days.from, to = days.to, days = #days.list,
        next_trading_close = day,
        quiet = calendar_quiet(days.to, nil) or nil,
    }
end
