-- engine/groups.lua — which region a stock belongs to, and which board.
--
-- Exports: groups_regions, groups_regions_refresh, groups_of, groups_label
--
-- The market snapshot already carries an industry and a listing board for
-- every stock. A REGION it does not: Eastmoney keeps that as its own set of
-- boards (31 of them — 广东板块, 江苏板块 …), one request each for the members.
-- So this fetches them once, stores the code → region map, and hands it out.
--
-- It is a map that changes when a company moves its registration, which is to
-- say almost never: REGION_TTL_DAYS is 30 and even that is generous.

local DOC = 'regions'

local cache = nil          -- the loaded document

local function load_doc()
    if cache then return cache end
    local doc, err = store_load(DOC)
    if err then cfg_log_warn('%s', err) end
    cache = doc or nil
    return cache
end

-- COROUTINE-ONLY. Fetch every region board and the stocks in it.
-- Returns the document, or nil plus (error code, message).
function g_exports.groups_regions_refresh()
    local boards, berr = source_em_fetch_sectors('region')
    if not boards or #boards.rows == 0 then
        return nil, 'upstream', '地域板块获取失败：' .. tostring(berr)
    end
    local by_code, names, counted = {}, {}, 0
    for _, b in ipairs(boards.rows) do
        local members, merr = source_em_fetch_board_members(b.code)
        if members then
            -- The board name is 「广东板块」; the region is what is left.
            local label = (b.name or b.code):gsub('板块$', '')
            names[#names + 1] = label
            for _, m in ipairs(members.rows) do
                -- A stock can appear in one region only, and the first one
                -- wins: Eastmoney's boards do not overlap, but a stale page
                -- during a move could say otherwise.
                if not by_code[m.code] then
                    by_code[m.code] = label
                    counted = counted + 1
                end
            end
        else
            cfg_log_warn('地域板块 %s（%s）成员获取失败：%s', b.code, tostring(b.name), tostring(merr))
        end
        sched_sleep(cfg_int('NET_PACE_MS', 200))
    end
    if counted == 0 then return nil, 'upstream', '一个地域板块的成员都没有取到' end

    local doc = { version = 1, fetched_at = util_now_iso(), regions = #names,
                  stocks = counted, by_code = by_code }
    local ok, serr = store_save(DOC, doc)
    if not ok then cfg_log_warn('地域映射保存失败：%s', tostring(serr)) end
    cache = doc
    cfg_log_info('regions: %d boards, %d stocks', #names, counted)
    return doc
end

-- The code → region map, fetching it once when it is missing or old.
-- COROUTINE-ONLY unless `offline`.
function g_exports.groups_regions(opts)
    opts = opts or {}
    local doc = load_doc()
    local stale = true
    if doc and doc.fetched_at then
        local days = util_date_diff_days(doc.fetched_at:sub(1, 10), util_today())
        stale = (days or 999) >= cfg_int('REGION_TTL_DAYS', 30)
    end
    if doc and (opts.offline or not stale) then return doc end
    if opts.offline then return doc end
    local fresh, ecode, emsg = groups_regions_refresh()
    if fresh then return fresh end
    if doc then
        cfg_log_warn('地域映射刷新失败，沿用 %s 的缓存：%s', tostring(doc.fetched_at), tostring(emsg))
        return doc
    end
    return nil, ecode, emsg
end

-- Every grouping a stock belongs to. `row` is a market snapshot row (or
-- anything carrying code / industry / board).
function g_exports.groups_of(row, regions)
    local code = row and row.code
    return {
        industry = row and row.industry or nil,
        board = row and row.board or (code and market_board(code)) or nil,
        region = (regions and regions.by_code and code) and regions.by_code[code] or nil,
    }
end

local BOARD_LABEL = { main = '主板', gem = '创业板', star = '科创板', bj = '北交所', other = '其他' }

function g_exports.groups_label(kind, value)
    if kind == 'board' then return BOARD_LABEL[value] or tostring(value) end
    return tostring(value)
end
