-- engine/source_dx.lua — memory-chip prices from DRAMeXchange (集邦 TrendForce).
--
-- Exports: source_dx_parse_spot, source_dx_fetch_spot,
--          source_dx_parse_contract, source_dx_fetch_contract
--
-- WHAT IS FREE, AND WHAT IS NOT. The home page carries today's spot prices —
-- DRAM chips daily, flash, wafers and modules roughly weekly — and two JSON
-- endpoints behind it carry the latest contract prices (about once a month).
-- The history behind every one of those numbers is for paying members only
-- (the chart pop-up answers "Only for MI members"). So there is no backfill:
-- xmoat keeps its own series from the day an item is first watched, one row
-- per publication, and a moving average over N rows needs N publications.
--
-- The spot tables are HTML, not an API. Each row names its item in the chart
-- link it carries (`item=dram&type=475`), and that pair is the stable id —
-- the display name has been reworded before, the chart type has not. Rows are
-- read by pattern, and a recorded page in test/fixtures/ is what says the
-- patterns still fit: a reworded page shows up as a failing test, not as a
-- watched item that silently stops moving.
--
-- Prices are US dollars per chip (per wafer, per module), as published.

local HOME = 'https://www.dramexchange.com/'
local HOME_PRICE = 'https://www.dramexchange.com/Home/HomePrice'
local CONTRACT_SOURCES = { dram = 'NationalDramContract', flash = 'NationalFlashContract' }

local MONTHS = { Jan = 1, Feb = 2, Mar = 3, Apr = 4, May = 5, Jun = 6,
                 Jul = 7, Aug = 8, Sep = 9, Oct = 10, Nov = 11, Dec = 12 }

local function text_of(fragment)
    local s = fragment:gsub('<[^>]*>', ' '):gsub('&nbsp;', ' '):gsub('&amp;', '&')
    return util_str_trim((s:gsub('%s+', ' ')))
end

-- Returns { items = { {id, group, name, date, high, low, avg, change_pct} } }
-- or nil plus a message. `id` is '<item>.<type>' from the chart link; `date`
-- is the day the table it sits in was last updated (GMT+8, as published).
function g_exports.source_dx_parse_spot(html)
    if type(html) ~= 'string' or html == '' then return nil, 'empty page' end
    -- Section titles and update stamps, by position: a row belongs to the last
    -- of each that comes before it. Several tables share one element id on
    -- this page, so position is the only thing that tells them apart.
    local titles, stamps = {}, {}
    for pos, title in html:gmatch('()<font face="Arial, Helvetica, sans%-serif">([%w ]-) Price</font>') do
        titles[#titles + 1] = { pos = pos, text = title }
    end
    for pos, mon, d, y in html:gmatch('()Last Update:%s*(%a+)%.%s*(%d+)%s+(%d%d%d%d)') do
        local m = MONTHS[mon]
        if m then
            stamps[#stamps + 1] = { pos = pos, date = string.format('%04d-%02d-%02d', tonumber(y), m, tonumber(d)) }
        end
    end
    local function last_before(list, pos)
        local hit
        for _, x in ipairs(list) do
            if x.pos < pos then hit = x else break end
        end
        return hit
    end

    local items, seen = {}, {}
    for pos, row in html:gmatch('()<td class="tab_tr_gray2">(.-)</tr>') do
        local cat, typ = row:match('item=(%a+)&amp;type=(%d+)')
        if not cat then cat, typ = row:match('item=(%a+)&type=(%d+)') end
        local name = text_of(row:match('^(.-)</td>') or '')
        local nums = {}
        for v in row:gmatch('<td class="tab_tr_gray">%s*([%d%.]+)%s*</td>') do nums[#nums + 1] = tonumber(v) end
        local change = row:match('tab_tr_font9">(.-)</td>')
        change = change and tonumber(text_of(change):match('(%-?[%d%.]+)%s*%%'))
        local id = cat and (cat:lower() .. '.' .. typ)
        local title, stamp = last_before(titles, pos), last_before(stamps, pos)
        -- Five numbers: the day's (or week's) high and low, the session's
        -- high and low, and the session average — the price.
        if id and not seen[id] and name ~= '' and #nums >= 5 and stamp then
            seen[id] = true
            items[#items + 1] = {
                id = id, group = title and title.text or cat, name = name, date = stamp.date,
                high = util_num(nums[3]), low = util_num(nums[4]), avg = util_num(nums[5]),
                change_pct = util_num(change),
            }
        end
    end
    if #items == 0 then return nil, 'no price rows found (page layout changed?)' end
    return { items = items }
end

-- COROUTINE-ONLY. One request for every spot item on the page.
function g_exports.source_dx_fetch_spot()
    local resp, err = net_get(HOME, { headers = { Accept = 'text/html,application/xhtml+xml' } })
    if not resp then return nil, err end
    return source_dx_parse_spot(resp.body)
end

-- `cat` is 'dram' or 'flash'. Returns { items = { {id, group, name, date,
-- high, low, avg, change_pct} } } or nil plus a message; change_pct is
-- against the previous contract period, as published.
function g_exports.source_dx_parse_contract(doc, cat)
    if type(doc) ~= 'table' then return nil, 'unexpected response shape (not a list)' end
    local items = {}
    for _, r in ipairs(doc) do
        local lid = tonumber(r.show_listid)
        local day = type(r.show_day) == 'string' and r.show_day:match('^(%d%d%d%d%-%d%d%-%d%d)')
        if lid and day and type(r.show_name) == 'string' then
            items[#items + 1] = {
                id = cat .. '.' .. math.floor(lid),
                group = cat == 'dram' and 'DRAM Contract' or 'NAND Flash Contract',
                name = util_str_trim((r.show_name:gsub('%s+', ' '))), date = day,
                high = util_num(r.show_hi), low = util_num(r.show_lo), avg = util_num(r.show_avg),
                change_pct = util_num(r.show_avg_change),
            }
        end
    end
    return { items = items }
end

-- COROUTINE-ONLY. Both contract tables, DRAM and flash. A table that fails is
-- reported in `errors` and the other is still returned; only both failing is
-- a failure.
function g_exports.source_dx_fetch_contract()
    local items, errors = {}, {}
    for _, cat in ipairs({ 'dram', 'flash' }) do
        local doc, err = net_get_json(HOME_PRICE .. '?Source=' .. CONTRACT_SOURCES[cat])
        local res = doc and source_dx_parse_contract(doc, cat)
        if res then
            for _, it in ipairs(res.items) do items[#items + 1] = it end
        else
            errors[#errors + 1] = cat .. ': ' .. tostring(err or 'unexpected response')
        end
    end
    if #items == 0 and #errors > 0 then return nil, table.concat(errors, '；') end
    return { items = items, errors = #errors > 0 and errors or nil }
end
