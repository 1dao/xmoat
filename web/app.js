// app.js — the xmoat web client.
//
// A pure client of /api/v1 (docs/API.md). It renders the analysis object the
// engine returns and does no financial arithmetic of its own — the rule that
// lets a phone app replace this page without the numbers changing.
//
// Every string that came from the API is inserted with textContent through h();
// there is no innerHTML anywhere in this file, so a company name or a dividend
// plan cannot become markup.
(function () {
  'use strict';

  // A host embedding this page elsewhere (a phone WebView pointed at a remote
  // engine) sets window.XMOAT_API_BASE before this script runs.
  const API_BASE = String(window.XMOAT_API_BASE || '').replace(/\/$/, '');
  const TOKEN_KEY = 'xmoat.api_token';

  const view = document.getElementById('view');
  const statusBox = document.getElementById('status');

  // ── DOM ────────────────────────────────────────────────────────────────────

  function h(tag, attrs, ...children) {
    const node = document.createElement(tag);
    for (const [k, v] of Object.entries(attrs || {})) {
      if (v === undefined || v === null || v === false) continue;
      if (k === 'class') node.className = v;
      else if (k === 'text') node.textContent = v;
      else if (k.startsWith('on')) node.addEventListener(k.slice(2), v);
      // No 'style' attribute: the CSP forbids inline styles, which is the point.
      else if (k === 'style') throw new Error('h(): use a class, not an inline style');
      else node.setAttribute(k, v === true ? '' : v);
    }
    for (const c of children.flat()) {
      if (c === undefined || c === null || c === false) continue;
      node.appendChild(typeof c === 'string' || typeof c === 'number' ? document.createTextNode(String(c)) : c);
    }
    return node;
  }

  function storage(fn) {
    try { return fn(window.localStorage); } catch (e) { return null; }
  }

  let statusTimer = null;
  function showStatus(message, isError) {
    clearTimeout(statusTimer);
    statusBox.textContent = message;
    statusBox.classList.toggle('is-error', !!isError);
    statusBox.hidden = false;
    if (!isError) statusTimer = setTimeout(() => { statusBox.hidden = true; }, 4000);
  }
  function clearStatus() { clearTimeout(statusTimer); statusBox.hidden = true; }

  // ── API ────────────────────────────────────────────────────────────────────

  class ApiError extends Error {
    constructor(code, message) { super(message); this.code = code; }
  }

  async function api(method, path, body, retried) {
    const headers = { Accept: 'application/json' };
    if (body !== undefined) headers['Content-Type'] = 'application/json';
    const token = storage(s => s.getItem(TOKEN_KEY));
    if (token) headers.Authorization = 'Bearer ' + token;

    let res;
    try {
      res = await fetch(API_BASE + path, {
        method, headers, body: body === undefined ? undefined : JSON.stringify(body),
      });
    } catch (e) {
      throw new ApiError('network', '连不上 xmoat 服务：' + e.message);
    }
    if (res.status === 401 && !retried) {
      const entered = window.prompt('这个 xmoat 服务需要访问令牌（API_TOKEN）：');
      if (entered) {
        storage(s => s.setItem(TOKEN_KEY, entered.trim()));
        return api(method, path, body, true);
      }
    }
    let doc = null;
    try { doc = await res.json(); } catch (e) { /* handled below */ }
    if (!doc || typeof doc.ok !== 'boolean') throw new ApiError('bad_response', '服务返回了无法识别的内容（HTTP ' + res.status + '）');
    if (!doc.ok) throw new ApiError(doc.error.code, doc.error.message);
    return doc.data;
  }

  const enc = encodeURIComponent;

  // ── formatting (presentation only: scale and digits, never arithmetic on meaning) ──

  const isNum = v => typeof v === 'number' && isFinite(v);

  function fmtNum(v, digits) {
    if (!isNum(v)) return '—';
    return v.toLocaleString('zh-CN', { minimumFractionDigits: digits ?? 2, maximumFractionDigits: digits ?? 2 });
  }
  function fmtPct(v, digits) { return isNum(v) ? fmtNum(v, digits ?? 1) + '%' : '—'; }
  function fmtMoney(v) {
    if (!isNum(v)) return '—';
    const a = Math.abs(v);
    if (a >= 1e12) return fmtNum(v / 1e12, 2) + ' 万亿';
    if (a >= 1e8) return fmtNum(v / 1e8, 2) + ' 亿';
    if (a >= 1e4) return fmtNum(v / 1e4, 1) + ' 万';
    return fmtNum(v, 0);
  }
  // `digits` is the engine's display hint (e.g. 2 for NPL ratios).
  function fmtUnit(v, unit, digits) {
    if (unit === '%') return fmtPct(v, digits);
    if (unit === 'pt') return isNum(v) ? fmtNum(v, 1) + 'pt' : '—';
    if (unit === 'x') return fmtNum(v, 2);
    if (unit === 'CNY') return fmtMoney(v);
    return fmtNum(v);
  }
  function fmtTime(iso) {
    if (!iso) return '—';
    const d = new Date(iso);
    if (isNaN(d)) return String(iso);
    const p = n => String(n).padStart(2, '0');
    return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}`;
  }

  const METRIC_LABEL = { pe_ttm: 'PE（TTM）', pb: 'PB', ps_ttm: 'PS（TTM）', pcf_ttm: 'PCF（TTM）' };
  const POSITION = { below: '低于区间', inside: '位于区间内', above: '高于区间' };
  const STATUS = {
    pass: { icon: '✓', tag: '通过' },
    warn: { icon: '!', tag: '注意' },
    na: { icon: '–', tag: '数据不足' },
  };

  function percentileMeter(p) {
    if (!isNum(p)) return h('span', { class: 'muted', text: '—' });
    const meter = h('span', { class: 'meter', 'aria-hidden': 'true' }, h('span'));
    meter.firstChild.style.width = Math.max(2, Math.min(100, p)) + '%';
    return h('span', { class: 'pct' }, meter, h('span', { class: 'num', text: fmtPct(p, 0) }));
  }

  // ── routing ────────────────────────────────────────────────────────────────

  let renderToken = 0;
  let activeChart = null;

  function route() {
    const token = ++renderToken;
    if (activeChart) { activeChart.destroy(); activeChart = null; }
    const m = location.hash.match(/^#\/stock\/([0-9A-Za-z.]+)$/);
    const page = m ? 'stock'
      : location.hash === '#/alerts' ? 'alerts'
      : location.hash === '#/screen' || location.hash === '#/screen/rules' ? 'screen'
      : location.hash === '#/review' ? 'review'
      : 'watchlist';
    for (const link of document.querySelectorAll('[data-nav]')) {
      if (link.dataset.nav === page) link.setAttribute('aria-current', 'page');
      else link.removeAttribute('aria-current');
    }
    if (m) return renderStock(m[1], token);
    if (page === 'alerts') return renderAlerts(token);
    if (page === 'screen') return renderScreen(token, location.hash === '#/screen/rules' ? 'rules' : 'custom');
    if (page === 'review') return renderReview(token);
    return renderWatchlist(token);
  }

  function stale(token) { return token !== renderToken; }

  function setView(...nodes) {
    view.textContent = '';
    for (const n of nodes.flat()) if (n) view.appendChild(n);
  }

  function loading(text) {
    return h('div', { class: 'card empty' }, h('p', { text: text || '加载中…' }));
  }

  function errorCard(err, retry) {
    return h('div', { class: 'card empty' },
      h('p', { text: err.message || String(err) }),
      retry ? h('p', {}, h('button', { class: 'btn', onclick: retry, text: '重试' })) : null);
  }

  // Run an action with its button disabled; report failure in the status bar.
  async function busy(button, label, fn) {
    const original = button.textContent;
    button.disabled = true;
    if (label) button.textContent = label;
    try { return await fn(); }
    catch (e) { showStatus(e.message, true); return undefined; }
    finally { button.disabled = false; button.textContent = original; }
  }

  // ── watchlist ──────────────────────────────────────────────────────────────

  async function renderWatchlist(token) {
    document.title = 'xmoat 护城河';
    setView(loading());
    let items;
    try { items = await api('GET', '/api/v1/watchlist'); }
    catch (e) { if (!stale(token)) setView(errorCard(e, route)); return; }
    if (stale(token)) return;

    const refreshAll = h('button', { class: 'btn', text: '全部刷新' });
    refreshAll.addEventListener('click', () => busy(refreshAll, '刷新中…', async () => {
      const results = await api('POST', '/api/v1/watchlist/refresh');
      const failed = results.filter(r => !r.ok);
      if (failed.length) showStatus(failed.map(r => `${r.code}：${r.error.message}`).join('；'), true);
      else showStatus(`已刷新 ${results.length} 只股票`);
      route();
    }));

    const head = h('div', { class: 'page-head' },
      h('h1', { text: '自选' }),
      h('span', { class: 'meta', text: `${items.length} 只` }),
      h('span', { class: 'spacer' }),
      items.length ? refreshAll : null);

    if (!items.length) {
      setView(head, h('div', { class: 'card empty' },
        h('p', { text: '还没有自选股。' }),
        h('p', { class: 'muted', text: '在右上角输入 A 股代码加入，例如 600519（贵州茅台）、000001（平安银行）。' })));
      return;
    }

    const rows = items.map(item => watchRow(item));
    const table = h('table', { class: 'watch-table' },
      h('thead', {}, h('tr', {},
        h('th', { text: '股票' }),
        h('th', { class: 'r', text: '收盘' }),
        h('th', { class: 'r', text: 'PE（TTM）' }),
        h('th', { text: 'PE 历史分位' }),
        h('th', { class: 'r', text: 'PB' }),
        h('th', { text: 'PB 历史分位' }),
        h('th', { class: 'r', text: '股息率' }),
        h('th', { text: '你的区间' }),
        h('th', { class: 'r', text: '注意' }),
        h('th', { text: '' }))),
      h('tbody', {}, rows));
    setView(head, h('div', { class: 'card' }, h('div', { class: 'table-wrap' }, table)));
  }

  function watchRow(item) {
    const s = item.summary;
    const open = () => { location.hash = '#/stock/' + item.code; };

    const refresh = h('button', { class: 'btn btn-small btn-quiet', text: '刷新' });
    refresh.addEventListener('click', e => {
      e.stopPropagation();
      busy(refresh, '…', async () => {
        await api('POST', `/api/v1/stocks/${enc(item.code)}/refresh`);
        route();
      });
    });
    const remove = h('button', { class: 'btn btn-small btn-quiet', text: '移除' });
    remove.addEventListener('click', e => {
      e.stopPropagation();
      if (!window.confirm(`把 ${s ? s.name : item.code} 移出自选？已获取的数据会保留。`)) return;
      busy(remove, '…', async () => {
        await api('DELETE', `/api/v1/watchlist/${enc(item.code)}`);
        route();
      });
    });

    const nameCell = h('td', { class: 'col-name' },
      h('span', { class: 'name', text: s ? s.name : '（尚未获取数据）' }), ' ',
      h('span', { class: 'code', text: item.code }),
      h('span', { class: 'sub', text: s ? [s.industry, s.date && ('估值 ' + s.date)].filter(Boolean).join(' · ') : '点“刷新”获取数据' }));

    const actions = h('td', { class: 'col-actions r' }, refresh, remove);
    if (!s) {
      return h('tr', { onclick: open }, nameCell,
        h('td', { colspan: '8', class: 'muted', text: '' }), actions);
    }
    const pe = s.pe_ttm || {}, pb = s.pb || {};
    const band = s.band;
    const warn = h('span', { class: 'badge' + (s.warnings ? ' is-warn' : ''), text: String(s.warnings ?? 0) });
    warn.setAttribute('title', s.warnings ? `${s.warnings} 项检查需要注意` : '检查清单没有提示');

    return h('tr', { onclick: open, tabindex: '0', onkeydown: e => { if (e.key === 'Enter') open(); } },
      nameCell,
      h('td', { class: 'r num', 'data-label': '收盘', text: fmtNum(s.close) }),
      h('td', { class: 'r num', 'data-label': 'PE（TTM）', text: fmtNum(pe.value, 1) }),
      h('td', { 'data-label': 'PE 分位（全部 / 近 5 年）' }, percentileMeter(pe.percentile_all),
        h('span', { class: 'sub', text: '近 5 年 ' + fmtPct(pe.percentile_y5, 0) })),
      h('td', { class: 'r num', 'data-label': 'PB', text: fmtNum(pb.value, 2) }),
      h('td', { 'data-label': 'PB 分位' }, percentileMeter(pb.percentile_all)),
      h('td', { class: 'r num', 'data-label': '股息率', text: fmtPct(s.dividend_yield, 2) }),
      h('td', { 'data-label': '你的区间' }, band
        ? h('span', { class: 'pos-' + band.position, text: POSITION[band.position] || '' })
        : h('span', { class: 'muted', text: '未设置' })),
      h('td', { class: 'r', 'data-label': '注意' }, warn),
      actions);
  }

  // ── one stock ──────────────────────────────────────────────────────────────

  async function renderStock(code, token) {
    setView(loading());
    let a;
    try {
      a = await api('GET', `/api/v1/stocks/${enc(code)}`);
    } catch (e) {
      if (stale(token)) return;
      if (e.code === 'not_fetched') return renderNotFetched(code, token, e);
      setView(errorCard(e, route));
      return;
    }
    if (stale(token)) return;
    document.title = `${a.name || a.code} · xmoat`;

    setView(
      stockHead(a),
      (a.notes || []).map(n => h('p', { class: 'note', text: n })),
      valuationCard(a),
      chartCard(a, token),
      levelsCard(a),
      technicalCard(a),
      qualityCard(a),
      businessCard(a),
      dividendCard(a),
      checksCard(a),
      backtestCard(a),
      insightCard(a, token),
      recentAlertsCard(a.code, token),
      sourcesLine(a));
    view.focus({ preventScroll: true });
  }

  function renderNotFetched(code, token, err) {
    const button = h('button', { class: 'btn btn-primary', text: '获取数据' });
    button.addEventListener('click', () => busy(button, '获取中…（首次可能要一分钟）', async () => {
      await api('POST', `/api/v1/stocks/${enc(code)}/refresh`);
      if (!stale(token)) route();
    }));
    setView(h('div', { class: 'page-head' }, h('h1', { text: code })),
      h('div', { class: 'card empty' }, h('p', { text: err.message }), h('p', {}, button)));
  }

  function stockHead(a) {
    const lr = a.latest_report;
    const meta = [
      `${a.code}.${a.market || ''}`,
      a.industry,
      lr && `最新报告 ${lr.name || lr.period}（公告 ${lr.notice_date || '—'}）`,
    ].filter(Boolean).join(' · ');

    const refresh = h('button', { class: 'btn', text: '刷新数据' });
    refresh.addEventListener('click', () => busy(refresh, '刷新中…', async () => {
      await api('POST', `/api/v1/stocks/${enc(a.code)}/refresh`);
      showStatus('已刷新');
      route();
    }));

    let watchBtn;
    if (a.watch) {
      watchBtn = h('button', { class: 'btn btn-quiet', text: '移出自选' });
      watchBtn.addEventListener('click', () => busy(watchBtn, null, async () => {
        await api('DELETE', `/api/v1/watchlist/${enc(a.code)}`);
        showStatus('已移出自选');
        route();
      }));
    } else {
      watchBtn = h('button', { class: 'btn btn-primary', text: '加入自选' });
      watchBtn.addEventListener('click', () => busy(watchBtn, null, async () => {
        await api('POST', '/api/v1/watchlist', { code: a.code });
        showStatus('已加入自选');
        route();
      }));
    }

    return h('div', { class: 'page-head' },
      h('div', {},
        h('div', { class: 'small' }, h('a', { href: '#/', text: '← 自选' })),
        h('h1', { text: a.name || a.code }),
        h('div', { class: 'meta', text: meta })),
      h('span', { class: 'spacer' }),
      refresh, watchBtn);
  }

  function valuationCard(a) {
    const v = a.valuation;
    const card = h('section', { class: 'card' });
    if (!v) {
      card.append(h('h2', { text: '估值' }), h('p', { class: 'muted', text: '没有估值数据。' }));
      return card;
    }
    card.append(h('div', { class: 'card-head' },
      h('h2', { text: '估值' }),
      h('span', { class: 'muted', text: `${v.date} 收盘 ${fmtNum(v.close)} · 总市值 ${fmtMoney(v.market_cap)}` })));

    const grid = h('div', { class: 'metric-grid' });
    for (const m of v.metrics || []) {
      const rows = h('dl', { class: 'rows' });
      const add = (label, value) => rows.append(h('dt', { text: label }), h('dd', {}, value));
      add('全部历史分位', m.all ? percentileMeter(m.all.percentile) : h('span', { class: 'muted small', text: m.all_note || '—' }));
      add('近 5 年分位', m.y5 ? percentileMeter(m.y5.percentile) : h('span', { class: 'muted small', text: m.y5_note || '—' }));
      if (m.all) {
        add('历史中位数', h('span', { class: 'num', text: fmtNum(m.all.median) }));
        add('历史区间', h('span', { class: 'num', text: `${fmtNum(m.all.min)} – ${fmtNum(m.all.max)}` }));
        add('样本', h('span', { class: 'muted', text: `${m.all.from} 起，${m.all.n} 个交易日` }));
      }
      grid.append(h('div', { class: 'metric' },
        h('div', { class: 'label', text: m.label }),
        h('div', { class: 'value', text: fmtNum(m.value) }),
        rows));
    }
    card.append(grid);

    const tiles = h('div', { class: 'tiles mt' });
    for (const x of v.extras || []) {
      tiles.append(h('div', { class: 'tile' },
        h('div', { class: 'label', text: x.label }),
        h('div', { class: 'value num', text: fmtNum(x.value) }),
        h('div', { class: 'foot', text: [x.basis, x.note].filter(Boolean).join('。') })));
    }
    const d = v.dividend || {};
    tiles.append(h('div', { class: 'tile' },
      h('div', { class: 'label', text: '股息率（近 12 个月）' }),
      h('div', { class: 'value', text: fmtPct(d.yield_ttm, 2) }),
      h('div', { class: 'foot', text: `每股派现 ${fmtNum(d.dps_ttm, 3)} 元，按除息日 ${d.from || ''} 至 ${d.to || ''}` })));

    const dcf = v.reverse_dcf || {};
    tiles.append(h('div', { class: 'tile' },
      h('div', { class: 'label', text: '反向 DCF：现价隐含的年化增长' }),
      h('div', { class: 'value', text: isNum(dcf.implied_growth)
        ? (dcf.bound === 'below' ? '低于 ' : dcf.bound === 'above' ? '高于 ' : '') + fmtPct(dcf.implied_growth)
        : '—' }),
      h('div', { class: 'foot', text: isNum(dcf.implied_growth)
        ? `${dcf.earnings_label} ${fmtMoney(dcf.earnings)}，未来 ${dcf.years} 年，折现率 ${fmtPct(dcf.discount_rate)}，永续增长 ${fmtPct(dcf.terminal_growth)}。${dcf.note || ''}`
        : (dcf.error || '') })));

    tiles.append(bandTile(a), positionTile(a));
    card.append(tiles);
    return card;
  }

  // 持仓 is also the switch for the price alerts, so the tile says so.
  function positionTile(a) {
    const pos = (a.watch && a.watch.position) || null;
    const tile = h('div', { class: 'tile' }, h('div', { class: 'label', text: '持仓' }));
    if (!a.watch) {
      tile.append(h('div', { class: 'foot', text: '加入自选后可以登记持仓。登记之后才会推送点位和技术面提醒。' }));
      return tile;
    }
    if (pos) {
      tile.append(h('div', { class: 'value', text: isNum(pos.profit_pct) ? fmtPct(pos.profit_pct) : '已持有' }),
        h('div', { class: 'foot', text: [
          isNum(pos.cost) ? `成本 ${fmtNum(pos.cost)}` : null,
          isNum(pos.shares) ? `${fmtNum(pos.shares, 0)} 股` : null,
          isNum(pos.market_value) ? `市值 ${fmtMoney(pos.market_value)}` : null,
          '点位与技术面提醒已开启',
        ].filter(Boolean).join('，') }));
    } else {
      tile.append(h('div', { class: 'foot', text: '未登记。登记持仓后，跌进买入区间、跌破止损、均线转向才会推送。' }));
    }

    const cost = h('input', { type: 'number', step: 'any', placeholder: '成本价', 'aria-label': '成本价', value: isNum(pos && pos.cost) ? pos.cost : undefined });
    const shares = h('input', { type: 'number', step: 'any', placeholder: '股数', 'aria-label': '股数', value: isNum(pos && pos.shares) ? pos.shares : undefined });
    const save = h('button', { class: 'btn btn-small', type: 'submit', text: pos ? '保存' : '登记持仓' });
    const clear = h('button', { class: 'btn btn-small btn-quiet', type: 'button', text: '清仓' });
    const form = h('form', { class: 'band-form mt-s' }, cost, shares, save, pos ? clear : null);
    form.addEventListener('submit', e => {
      e.preventDefault();
      const num = input => (input.value === '' ? null : Number(input.value));
      busy(save, '…', async () => {
        await api('PATCH', `/api/v1/watchlist/${enc(a.code)}`, { position: { cost: num(cost), shares: num(shares) } });
        showStatus('持仓已保存，点位与技术面提醒已开启');
        route();
      });
    });
    clear.addEventListener('click', () => busy(clear, '…', async () => {
      await api('PATCH', `/api/v1/watchlist/${enc(a.code)}`, { position: null });
      showStatus('已清仓，不再推送点位提醒');
      route();
    }));
    tile.append(form);
    return tile;
  }

  function bandTile(a) {
    const band = a.valuation && a.valuation.band;
    const current = (a.watch && a.watch.band) || {};
    const tile = h('div', { class: 'tile' }, h('div', { class: 'label', text: '你的合理估值区间' }));
    if (band) {
      tile.append(h('div', { class: 'value pos-' + band.position, text: POSITION[band.position] }),
        h('div', { class: 'foot', text: `${METRIC_LABEL[band.metric] || band.metric} 当前 ${fmtNum(band.value)}，区间 ${isNum(band.low) ? fmtNum(band.low) : '不限'} – ${isNum(band.high) ? fmtNum(band.high) : '不限'}` }));
    }
    if (!a.watch) {
      tile.append(h('div', { class: 'foot', text: '加入自选后可以设置。区间由你自己定，引擎只报告价格落在哪里。' }));
      return tile;
    }

    const metric = h('select', { 'aria-label': '指标' },
      Object.entries(METRIC_LABEL).map(([k, label]) => h('option', { value: k, text: label, selected: (current.metric || 'pe_ttm') === k })));
    const low = h('input', { type: 'number', step: 'any', placeholder: '下限', 'aria-label': '下限', value: isNum(current.low) ? current.low : undefined });
    const high = h('input', { type: 'number', step: 'any', placeholder: '上限', 'aria-label': '上限', value: isNum(current.high) ? current.high : undefined });
    const save = h('button', { class: 'btn btn-small', type: 'submit', text: '保存' });
    const clear = h('button', { class: 'btn btn-small btn-quiet', type: 'button', text: '清除' });

    const form = h('form', { class: 'band-form mt-s' }, metric, low, high, save, band ? clear : null);
    form.addEventListener('submit', e => {
      e.preventDefault();
      const num = input => (input.value === '' ? null : Number(input.value));
      busy(save, '…', async () => {
        await api('PATCH', `/api/v1/watchlist/${enc(a.code)}`, { band: { metric: metric.value, low: num(low), high: num(high) } });
        showStatus('区间已保存');
        route();
      });
    });
    clear.addEventListener('click', () => busy(clear, '…', async () => {
      await api('PATCH', `/api/v1/watchlist/${enc(a.code)}`, { band: null });
      showStatus('区间已清除');
      route();
    }));
    tile.append(form);
    return tile;
  }

  function chartCard(a, token) {
    const card = h('section', { class: 'card' });
    if (!a.valuation) return null;
    const state = { metric: 'pe_ttm', window: 'all', table: false };
    const chartBox = h('div');
    const tableBox = h('div', { class: 'table-wrap', hidden: true });

    function segmented(options, key) {
      const group = h('div', { class: 'seg', role: 'group' });
      for (const [value, label] of options) {
        const b = h('button', { type: 'button', text: label, 'aria-pressed': String(state[key] === value) });
        b.addEventListener('click', () => {
          state[key] = value;
          for (const other of group.children) other.setAttribute('aria-pressed', String(other === b));
          load();
        });
        group.append(b);
      }
      return group;
    }

    const tableBtn = h('button', { class: 'btn btn-small btn-quiet', type: 'button', text: '表格' });
    tableBtn.addEventListener('click', () => {
      state.table = !state.table;
      tableBox.hidden = !state.table;
      tableBtn.textContent = state.table ? '收起表格' : '表格';
    });

    const title = h('h2', { text: '估值走势' });
    card.append(h('div', { class: 'card-head' }, title, h('span', { class: 'spacer' }),
      segmented(Object.entries(METRIC_LABEL), 'metric'),
      segmented([['y5', '近 5 年'], ['all', '全部']], 'window'),
      tableBtn), chartBox, tableBox,
      h('p', { class: 'muted small', text: '横线为所选时间段的历史中位数；阴影为你设置的合理区间（指标一致时显示）。' }));

    async function load() {
      chartBox.style.opacity = '0.5';
      const params = `metric=${state.metric}` + (state.window === 'y5' ? '&years=5' : '');
      let series;
      try { series = await api('GET', `/api/v1/stocks/${enc(a.code)}/valuation?${params}`); }
      catch (e) { chartBox.style.opacity = ''; showStatus(e.message, true); return; }
      if (stale(token)) return;
      chartBox.style.opacity = '';

      const metric = (a.valuation.metrics || []).find(m => m.key === state.metric) || {};
      const stats = state.window === 'y5' ? metric.y5 : metric.all;
      const band = a.valuation.band && a.valuation.band.metric === state.metric ? a.valuation.band : null;
      title.textContent = `${METRIC_LABEL[state.metric]} 走势`;
      if (activeChart) activeChart.destroy();
      activeChart = window.XmoatChart.line(chartBox, {
        points: series.points,
        format: v => fmtNum(v, Math.abs(v) >= 100 ? 0 : Math.abs(v) >= 10 ? 1 : 2),
        median: stats ? stats.median : undefined,
        band,
        ariaLabel: `${a.name} ${METRIC_LABEL[state.metric]} 走势，${series.from || ''} 至 ${series.to || ''}`,
      });

      // The table twin: the last available day of each month.
      const byMonth = new Map();
      for (const p of series.points) if (isNum(p[1])) byMonth.set(String(p[0]).slice(0, 7), p);
      const rows = [...byMonth.values()].reverse().map(p =>
        h('tr', {}, h('td', { class: 'num', text: p[0] }), h('td', { class: 'r num', text: fmtNum(p[1]) })));
      tableBox.textContent = '';
      tableBox.append(h('table', {},
        h('thead', {}, h('tr', {}, h('th', { text: '日期（每月最后一个有数据的交易日）' }), h('th', { class: 'r', text: METRIC_LABEL[state.metric] }))),
        h('tbody', {}, rows)));
    }
    load();
    return card;
  }

  function qualityCard(a) {
    const q = a.quality;
    const card = h('section', { class: 'card' }, h('h2', { text: '经营质量（年报）' }));
    if (!q || !(q.periods || []).length) {
      card.append(h('p', { class: 'muted', text: '没有年报数据。' }));
      return card;
    }
    const tiles = h('div', { class: 'tiles mb' });
    for (const s of q.summary || []) {
      tiles.append(h('div', { class: 'tile' },
        h('div', { class: 'label', text: s.label }),
        h('div', { class: 'value num', text: fmtUnit(s.value, s.unit, s.digits) }),
        s.basis ? h('div', { class: 'foot', text: s.basis }) : null));
    }
    card.append(tiles);

    const years = q.periods.map(p => String(p).slice(0, 4));
    const table = h('table', { class: 'quality-table' },
      h('thead', {}, h('tr', {}, h('th', { text: '指标' }), years.map(y => h('th', { class: 'r', text: y })))),
      h('tbody', {}, (q.series || []).map(s => h('tr', {},
        h('td', { text: s.label }),
        (s.values || []).map(v => h('td', { class: 'r num', text: fmtUnit(v, s.unit, s.digits) }))))));
    card.append(h('div', { class: 'table-wrap' }, table),
      h('p', { class: 'muted small', text: '各年年报口径；公告日期见数据源。营收、利润单位为元，按亿显示。' }));
    return card;
  }

  function dividendCard(a) {
    const d = a.dividends;
    const card = h('section', { class: 'card' });
    card.append(h('div', { class: 'card-head' }, h('h2', { text: '分红' }),
      d && d.latest_fy ? h('span', { class: 'muted', text: `截至 ${d.latest_fy} 年报，连续 ${d.consecutive_years} 年分红` }) : null));
    if (!d || !(d.years || []).length) {
      card.append(h('p', { class: 'muted', text: '没有分红记录。' }));
      return card;
    }
    card.append(h('div', { class: 'table-wrap' }, h('table', {},
      h('thead', {}, h('tr', {}, h('th', { text: '年度' }), h('th', { class: 'r', text: '每股派现（元，含税）' }),
        h('th', { class: 'r', text: '每股收益' }), h('th', { class: 'r', text: '分红率' }))),
      h('tbody', {}, d.years.map(y => h('tr', {},
        h('td', { class: 'num', text: String(y.year) }),
        h('td', { class: 'r num', text: fmtNum(y.dps, 3) }),
        h('td', { class: 'r num', text: fmtNum(y.eps, 2) }),
        h('td', { class: 'r num', text: fmtPct(y.payout_ratio) })))))));
    if ((d.pending || []).length) {
      card.append(h('p', { class: 'muted small', text: '尚未除息的方案：' + d.pending.map(p => `${p.period} ${p.plan || ''}（${p.progress || ''}）`).join('；') }));
    }
    return card;
  }

  function checksCard(a) {
    const card = h('section', { class: 'card' }, h('h2', { text: '检查清单' }));
    const list = h('ul', { class: 'checks' });
    for (const c of a.checks || []) {
      const st = STATUS[c.status] || STATUS.na;
      list.append(h('li', { class: c.status },
        h('span', { class: 'icon', 'aria-hidden': 'true', text: st.icon }),
        h('div', {}, h('span', { class: 'title', text: c.title }), h('span', { class: 'tag', text: st.tag })),
        h('div', { class: 'detail', text: c.detail || '' })));
    }
    card.append(list, h('p', { class: 'muted small', text: '阈值是经验规则，不是结论：提示意味着值得打开年报看一看。' }));
    return card;
  }

  // ── levels ─────────────────────────────────────────────────────────────────

  function levelsCard(a) {
    const lv = a.levels;
    if (!lv) return null;
    const card = h('section', { class: 'card' });
    card.append(h('div', { class: 'card-head' }, h('h2', { text: '点位' }),
      h('span', { class: 'muted', text: lv.note ? '' : `锚：${lv.metric_label} ${fmtNum(lv.metric_now)}` })));
    if (lv.note) {
      card.append(h('p', { class: 'muted', text: '算不出来：' + lv.note }));
      return card;
    }

    const kv = h('dl', { class: 'kv' });
    const row = (k, v) => { if (v) kv.append(h('dt', { text: k }), h('dd', {}, v)); };
    const withBasis = (main, basis) => h('span', {},
      h('span', { class: 'num', text: main }),
      h('span', { class: 'muted small', text: '　' + basis }));

    if (lv.buy && isNum(lv.buy.high)) {
      const main = isNum(lv.buy.low)
        ? `${fmtNum(lv.buy.low)} – ${fmtNum(lv.buy.high)}`
        : `${fmtNum(lv.buy.high)} 以下`;
      row('买入', withBasis(main, lv.buy.basis || ''));
    }
    if (lv.target) {
      row('目标', withBasis(`${fmtNum(lv.target.price)}（${fmtPct(lv.target.upside, 1)}）`, lv.target.basis || ''));
    }
    if (lv.stop) {
      row('止损', withBasis(`${fmtNum(lv.stop.price)}（${fmtPct(lv.stop.downside, 1)}）`, lv.stop.basis || ''));
    }
    if (isNum(lv.reward_risk)) {
      row('盈亏比', h('span', { class: 'num', text: fmtNum(lv.reward_risk, 2) }));
    }
    const w = lv.window;
    if (w) {
      row('样本', h('span', { class: 'muted', text: `${w.from} 起 ${w.n} 个交易日，中位数 ${fmtNum(w.median)}，当前分位 ${fmtPct(w.percentile, 0)}` }));
    }
    card.append(kv);
    for (const n of lv.notes || []) card.append(h('p', { class: 'muted small', text: n }));
    return card;
  }

  // ── technical ──────────────────────────────────────────────────────────────

  const ALIGNMENT = { bull: '多头排列', bear: '空头排列', none: '未形成排列' };

  function technicalCard(a) {
    const t = a.technical;
    if (!t) return null;
    const card = h('section', { class: 'card' });
    const when = t.as_of ? `${t.as_of} 收盘 ${fmtNum(t.close)}` : '';
    card.append(h('div', { class: 'card-head' }, h('h2', { text: '技术面' }),
      h('span', { class: 'muted', text: when })));
    if (t.note) {
      card.append(h('p', { class: 'muted', text: t.note }));
      return card;
    }

    const kv = h('dl', { class: 'kv' });
    const row = (k, v) => { if (v) kv.append(h('dt', { text: k }), h('dd', {}, v)); };
    const tags = xs => h('span', { class: 'channel-list' },
      xs.map(x => h('span', { class: 'tag', text: x })));

    const mas = [5, 10, 20, 60, 120, 250]
      .filter(n => isNum(t.ma && t.ma[n])).map(n => `MA${n} ${fmtNum(t.ma[n])}`);
    if (mas.length) row('均线', tags(mas));
    const tr = t.trend || {};
    row('排列', h('span', { text: `${ALIGNMENT[tr.alignment] || '—'}，收盘价在 ${tr.above_ma || 0}/${tr.ma_count || 0} 条均线上方` }));
    const bias = [6, 12, 24, 60]
      .filter(n => isNum(t.bias && t.bias[n])).map(n => `BIAS${n} ${fmtPct(t.bias[n], 1)}`);
    if (bias.length) row('乖离率', tags(bias));
    const r = t.range_250;
    if (r && isNum(r.high) && isNum(r.low)) {
      row('位置', h('span', { text: `近 ${r.days} 个交易日 ${fmtNum(r.low)}–${fmtNum(r.high)}，当前分位 ${fmtPct(r.position, 0)}，距高点 ${fmtPct(r.from_high, 1)}` }));
    }
    if (isNum(t.volume_ratio)) {
      row('量能', h('span', { text: `${fmtNum(t.volume_ratio, 2)}（5 日均量 / 60 日均量）` }));
    }
    const c = t.chips;
    if (c) {
      row('筹码', h('span', { text: `平均成本 ${fmtNum(c.avg_cost)}，获利比例 ${fmtPct(c.profit_ratio, 0)}，90% 成本区间 ${fmtNum(c.low_90)}–${fmtNum(c.high_90)}，集中度 ${fmtPct(c.concentration_90, 0)}` }));
    } else if (t.chips_note) {
      row('筹码', h('span', { class: 'muted', text: t.chips_note }));
    }
    card.append(kv, h('p', { class: 'muted small', text: '技术面只回答价格在什么位置，不回答公司值不值得买。筹码分布是按换手率估算出来的模型，不是真实持仓，口径见 docs/METRICS.md。' }));
    return card;
  }

  // ── business breakdown ─────────────────────────────────────────────────────

  function businessCard(a) {
    const b = a.business;
    if (!b || !b.period) return null;
    const card = h('section', { class: 'card' });
    card.append(h('div', { class: 'card-head' }, h('h2', { text: '主营构成' }),
      h('span', { class: 'muted', text: `${b.period} 年报${b.previous_period ? '，占比变化对比 ' + b.previous_period.slice(0, 4) + ' 年' : ''}` })));
    const NAMES = { product: '按产品', region: '按地区', industry: '按行业' };
    for (const kind of ['product', 'region', 'industry']) {
      const list = (b.by && b.by[kind]) || [];
      if (!list.length) continue;
      card.append(h('div', { class: 'table-wrap mb' }, h('table', {},
        h('thead', {}, h('tr', {},
          h('th', { text: NAMES[kind] }), h('th', { class: 'r', text: '收入' }),
          h('th', { class: 'r', text: '占比' }), h('th', { class: 'r', text: '占比变化' }),
          h('th', { class: 'r', text: '毛利率' }))),
        h('tbody', {}, list.map(s => h('tr', {},
          h('td', { text: s.name }),
          h('td', { class: 'r num', text: fmtMoney(s.revenue) }),
          h('td', { class: 'r num', text: fmtPct(s.revenue_share) }),
          h('td', { class: 'r num', text: isNum(s.share_change) ? (s.share_change >= 0 ? '+' : '') + fmtNum(s.share_change, 1) + 'pt' : '—' }),
          h('td', { class: 'r num', text: fmtPct(s.gross_margin) })))))));
    }
    if (b.scope) card.append(h('p', { class: 'muted small', text: '经营范围：' + b.scope }));
    return card;
  }

  // ── backtest ───────────────────────────────────────────────────────────────

  const SIGNAL_LABEL = {
    value: '估值分位偏低',
    trend: '均线多头排列',
    value_trend: '低估值 + 多头排列',
    band: '低于我设的区间下沿',
  };

  function backtestTables(r) {
    const box = h('div');
    if (r.note) { box.append(h('p', { class: 'muted', text: r.note })); return box; }
    box.append(h('p', { class: 'muted small', text:
      `${r.from} – ${r.to}　触发 ${r.entries} 次（可判定的交易日 ${r.tested} 个，两次信号至少间隔 ${r.cooldown} 个交易日）` }));

    const base = {};
    for (const b of (r.baseline || {}).horizons || []) base[b.days] = b;
    box.append(h('div', { class: 'label-sm', text: '方向胜率' }));
    box.append(h('div', { class: 'table-wrap mb' }, h('table', {},
      h('thead', {}, h('tr', {},
        h('th', { text: '持有' }), h('th', { class: 'r', text: '次数' }),
        h('th', { class: 'r', text: '胜率' }), h('th', { class: 'r', text: '基准胜率' }),
        h('th', { class: 'r', text: '平均收益' }), h('th', { class: 'r', text: '基准平均' }),
        h('th', { class: 'r', text: '最好' }), h('th', { class: 'r', text: '最差' }))),
      h('tbody', {}, (r.horizons || []).map(hz => {
        const b = base[hz.days] || {};
        return h('tr', {},
          h('td', { text: hz.days + ' 日' }),
          h('td', { class: 'r num', text: String(hz.n || 0) }),
          h('td', { class: 'r num', text: fmtPct(hz.win_rate, 0) }),
          h('td', { class: 'r num muted', text: fmtPct(b.win_rate, 0) }),
          h('td', { class: 'r num', text: fmtPct(hz.avg, 1) }),
          h('td', { class: 'r num muted', text: fmtPct(b.avg, 1) }),
          h('td', { class: 'r num', text: fmtPct(hz.best, 1) }),
          h('td', { class: 'r num', text: fmtPct(hz.worst, 1) }));
      })))));

    const br = r.barrier || {}, bb = (r.baseline || {}).barrier || {};
    box.append(h('div', { class: 'label-sm', text:
      `止盈止损（止盈 ${fmtPct(br.take_profit, 0)}，止损 ${fmtPct(br.stop_loss, 0)}，最多 ${br.horizon} 个交易日）` }));
    const brow = (k, a, b) => h('tr', {}, h('td', { text: k }),
      h('td', { class: 'r num', text: a }), h('td', { class: 'r num muted', text: b }));
    box.append(h('div', { class: 'table-wrap mb' }, h('table', {},
      h('thead', {}, h('tr', {}, h('th', { text: '' }),
        h('th', { class: 'r', text: '信号' }), h('th', { class: 'r', text: '基准' }))),
      h('tbody', {},
        brow('先到止盈', `${br.hit_tp || 0}（${fmtPct(br.tp_rate, 0)}）`, `${bb.hit_tp || 0}（${fmtPct(bb.tp_rate, 0)}）`),
        brow('先到止损', `${br.hit_sl || 0}（${fmtPct(br.sl_rate, 0)}）`, `${bb.hit_sl || 0}（${fmtPct(bb.sl_rate, 0)}）`),
        brow('都没到', String(br.neither || 0), String(bb.neither || 0)),
        brow('止盈命中率', fmtPct(br.win_rate, 0), fmtPct(bb.win_rate, 0))))));
    if (br.both_same_day) {
      box.append(h('p', { class: 'muted small', text:
        `其中 ${br.both_same_day} 次在同一天既触及止盈也触及止损，按止损计：日线看不出谁先到，算成赢是那种让回测都好看的假设。` }));
    }
    for (const n of r.notes || []) box.append(h('p', { class: 'muted small', text: n }));
    return box;
  }

  function backtestCard(a) {
    const card = h('section', { class: 'card' });
    const select = h('select', { 'aria-label': '信号' },
      Object.keys(SIGNAL_LABEL).map(k => h('option', { value: k, text: SIGNAL_LABEL[k] })));
    const run = h('button', { class: 'btn', text: '运行回测' });
    const body = h('div');
    card.append(h('div', { class: 'card-head' }, h('h2', { text: '回测验证' }),
      h('span', { class: 'spacer' }), select, run), body);
    body.append(h('p', { class: 'muted', text: '在这只股票自己的历史上回放信号，看当时买入之后发生了什么。旁边一列是同一段时间里「随便哪天买」的同样统计——信号没有明显好过它，就说明这条规则没有加东西。' }));

    run.addEventListener('click', () => busy(run, '回放中…', async () => {
      const r = await api('GET', `/api/v1/stocks/${enc(a.code)}/backtest?signal=${enc(select.value)}`);
      body.textContent = '';
      body.append(h('p', { class: 'muted small', text: r.signal_note || '' }), backtestTables(r));
    }));
    return card;
  }

  // ── language-model reading ─────────────────────────────────────────────────

  function list(title, items) {
    if (!items || !items.length) return null;
    return h('div', { class: 'mt' }, h('div', { class: 'label-sm', text: title }),
      h('ul', { class: 'plain' }, items.map(x => h('li', { text: x }))));
  }

  function unverifiedNote(nums) {
    if (!nums || !nums.length) return null;
    return h('p', { class: 'warn-note', text: `以下数字没有出现在提供给模型的事实里，可能是模型自己算的或编的，请勿直接采信：${nums.join('、')}` });
  }

  function insightCard(a, token) {
    const card = h('section', { class: 'card' });
    const head = h('div', { class: 'card-head' }, h('h2', { text: '大模型解读' }), h('span', { class: 'spacer' }));
    const body = h('div');
    card.append(head, body);

    Promise.all([api('GET', '/api/v1/llm'), api('GET', `/api/v1/stocks/${enc(a.code)}/insight`).catch(e => {
      if (e.code === 'not_found') return null;
      throw e;
    })]).then(([llm, ins]) => {
      if (stale(token)) return;
      if (!llm.enabled) {
        body.append(h('p', { class: 'muted', text: '未配置大模型。' + (llm.hint || '') }));
        if (!ins) return;
      }
      if (llm.enabled) {
        const gen = h('button', { class: 'btn btn-small', text: ins ? '重新生成' : '生成解读' });
        gen.addEventListener('click', () => busy(gen, '生成中…', async () => {
          await api('POST', `/api/v1/stocks/${enc(a.code)}/insight`);
          showStatus('解读已生成');
          route();
        }));
        head.append(gen);
      }
      if (ins) body.append(renderInsight(ins));
      if (llm.enabled) body.append(askBox(a.code));
    }).catch(e => { body.append(h('p', { class: 'muted', text: e.message })); });
    return card;
  }

  function renderInsight(ins) {
    const r = ins.result;
    const box = h('div');
    box.append(h('p', { class: 'note', text: '以下内容由大模型根据上方已算好的数字和公司经营评述生成，是解读而不是事实；程序已核对其中的数字。' }));
    if (!r) {
      box.append(h('p', { class: 'muted', text: '模型的回答没有按要求的格式返回：' + (ins.parse_error || '') }),
        h('pre', { class: 'raw', text: ins.raw || '' }));
    } else {
      box.append(h('p', { class: 'insight-summary', text: r.summary }));
      box.append(h('dl', { class: 'kv' },
        h('dt', { text: '护城河强度' }), h('dd', { text: r.moat.strength }),
        h('dt', { text: '来源' }), h('dd', { text: (r.moat.sources || []).join('、') || '—' })));
      box.append(list('证据', r.moat.evidence), list('变化', r.changes), list('风险', r.risks),
        list('值得核实的问题', r.questions));
    }
    box.append(unverifiedNote(ins.unverified) || h('span'));
    box.append(h('p', { class: 'muted small', text: `${ins.provider || ''} ${ins.model || ''} · ${fmtTime(ins.created_at)} · 依据 ${ins.report_period || '—'} 报告、${ins.valuation_date || '—'} 估值` }));
    return box;
  }

  function askBox(code) {
    const history = [];
    const log = h('div', { class: 'qa-log' });
    const input = h('input', { type: 'text', maxlength: '500', placeholder: '就这家公司提问，例如：毛利率为什么这么高？', 'aria-label': '问题' });
    const send = h('button', { class: 'btn btn-small', type: 'submit', text: '提问' });
    const form = h('form', { class: 'ask-form mt' }, input, send);
    form.addEventListener('submit', e => {
      e.preventDefault();
      const question = input.value.trim();
      if (!question) return;
      busy(send, '…', async () => {
        const res = await api('POST', `/api/v1/stocks/${enc(code)}/ask`, { question, history: history.slice(-6) });
        history.push({ role: 'user', content: question }, { role: 'assistant', content: res.answer });
        log.append(h('div', { class: 'qa' },
          h('div', { class: 'q', text: '问：' + question }),
          h('div', { class: 'a', text: res.answer }),
          unverifiedNote(res.unverified)));
        input.value = '';
      });
    });
    return h('div', { class: 'mt' }, h('div', { class: 'label-sm', text: '提问（回答只依据上面的事实，会产生模型费用）' }), log, form);
  }

  // ── screening the whole market ─────────────────────────────────────────────

  const SCREEN_FIELDS = [
    { name: 'roe_min', label: 'ROE ≥', unit: '%' },
    { name: 'pe_max', label: 'PE(TTM) ≤' },
    { name: 'pb_max', label: 'PB ≤' },
    { name: 'cap_min', label: '市值 ≥', unit: '亿' },
    { name: 'np_yoy_min', label: '净利同比 ≥', unit: '%' },
    { name: 'revenue_yoy_min', label: '营收同比 ≥', unit: '%' },
    { name: 'gross_margin_min', label: '毛利率 ≥', unit: '%' },
    { name: 'ocf_to_eps_min', label: '现金流/EPS ≥' },
  ];
  const BOARDS = [['main', '主板'], ['gem', '创业板'], ['star', '科创板'], ['bj', '北交所']];
  const SCREEN_SORTS = [['roe', 'ROE'], ['pe_ttm', 'PE(TTM)'], ['pb', 'PB'], ['market_cap', '市值'],
    ['np_parent_yoy', '净利同比'], ['revenue_yoy', '营收同比'], ['gross_margin', '毛利率']];
  // The last screen, kept for this browser only, so the page comes back as it was.
  const SCREEN_KEY = 'xmoat.screen';

  function readScreenForm(form) {
    const q = {};
    for (const el of form.elements) {
      if (!el.name || el.type === 'submit') continue;
      if (el.type === 'checkbox') {
        if (el.name === 'boards') continue;
        if (el.checked) q[el.name] = 'true';
      } else if (el.value !== '') q[el.name] = el.value;
    }
    const boards = [...form.querySelectorAll('input[name="boards"]:checked')].map(b => b.value);
    if (boards.length && boards.length < BOARDS.length) q.boards = boards.join(',');
    return q;
  }

  // Two ways to narrow the market: conditions on the snapshot the user sets
  // (定制规则), and the rules the engine ships with their fitted numbers
  // (内置规则). Each has its own address, so a reload stays on the same one.
  function screenTabs(tab) {
    const group = h('div', { class: 'seg screen-tabs', role: 'group', 'aria-label': '筛选方式' });
    for (const [value, label, hash] of [['custom', '定制规则', '#/screen'], ['rules', '内置规则', '#/screen/rules']]) {
      group.append(h('button', { type: 'button', text: label, 'aria-pressed': String(tab === value),
        onclick: () => { if (location.hash !== hash) location.hash = hash; } }));
    }
    return group;
  }

  async function renderScreen(token, tab) {
    document.title = (tab === 'rules' ? '内置规则' : '筛选') + ' · xmoat';
    setView(loading());
    let status, rules;
    try {
      [status, rules] = await Promise.all([
        api('GET', '/api/v1/market'),
        tab === 'rules' ? api('GET', '/api/v1/strategy/rules') : null,
      ]);
    } catch (e) { if (!stale(token)) setView(errorCard(e, route)); return; }
    if (stale(token)) return;

    const saved = (() => {
      try { return JSON.parse(storage(s => s.getItem(SCREEN_KEY)) || '{}'); } catch (e) { return {}; }
    })();

    const refresh = h('button', { class: status.ready ? 'btn' : 'btn btn-primary',
      text: status.ready ? '刷新快照' : '抓取快照' });
    refresh.addEventListener('click', () => busy(refresh, '抓取中…', async () => {
      const st = await api('POST', '/api/v1/market/refresh');
      showStatus(`快照已更新：${st.total} 只，估值 ${st.trade_date}，业绩 ${st.report_period}`);
      route();
    }));

    const head = h('div', { class: 'page-head' },
      h('h1', { text: '筛选' }),
      h('span', { class: 'meta', text: status.ready
        ? `${status.total} 只 · 估值 ${status.trade_date} · 业绩 ${status.report_period}`
        : '还没有快照' }),
      h('span', { class: 'spacer' }), refresh);

    if (!status.ready) {
      setView(head, screenTabs(tab), h('div', { class: 'card empty' },
        h('p', { text: status.hint || '还没有全市场快照。' }),
        h('p', { class: 'muted', text: '快照包含当日估值和最近一个年报的业绩，抓一次约十几秒。' })));
      return;
    }

    if (tab === 'rules') {
      setView(head, screenTabs(tab), rules.flatMap(rule => ruleCard(rule, token)));
      return;
    }

    const form = h('form', { class: 'screen-form' });
    for (const f of SCREEN_FIELDS) {
      form.append(h('label', { class: 'field' },
        h('span', { text: f.label + (f.unit ? `（${f.unit}）` : '') }),
        h('input', { type: 'number', step: 'any', name: f.name, value: saved[f.name] ?? undefined })));
    }
    form.append(h('label', { class: 'field' }, h('span', { text: '行业包含' }),
      h('input', { type: 'text', name: 'industry', value: saved.industry ?? undefined })));
    form.append(h('label', { class: 'field' }, h('span', { text: '名称或代码' }),
      h('input', { type: 'text', name: 'keyword', value: saved.keyword ?? undefined })));

    const savedBoards = (saved.boards || '').split(',').filter(Boolean);
    const boardBox = h('div', { class: 'field' }, h('span', { text: '板块' }));
    const boardRow = h('div', { class: 'checks-row' });
    for (const [value, label] of BOARDS) {
      boardRow.append(h('label', { class: 'check' },
        h('input', { type: 'checkbox', name: 'boards', value,
          checked: savedBoards.length === 0 || savedBoards.includes(value) }),
        h('span', { text: label })));
    }
    boardRow.append(h('label', { class: 'check' },
      h('input', { type: 'checkbox', name: 'include_st', checked: saved.include_st === 'true' }),
      h('span', { text: '包含 ST' })));
    boardBox.append(boardRow);
    form.append(boardBox);

    form.append(h('label', { class: 'field' }, h('span', { text: '排序' }),
      h('select', { name: 'sort' }, SCREEN_SORTS.map(([v, l]) =>
        h('option', { value: v, text: l, selected: (saved.sort || 'roe') === v })))));
    form.append(h('label', { class: 'field' }, h('span', { text: '方向' }),
      h('select', { name: 'order' },
        h('option', { value: 'desc', text: '从高到低', selected: (saved.order || 'desc') === 'desc' }),
        h('option', { value: 'asc', text: '从低到高', selected: saved.order === 'asc' }))));

    const run = h('button', { class: 'btn btn-primary', type: 'submit', text: '筛选' });
    const reset = h('button', { class: 'btn btn-quiet', type: 'button', text: '清空' });
    form.append(h('div', { class: 'field field-actions' }, run, reset));

    const results = h('section', { class: 'card' },
      h('p', { class: 'muted', text: '设好条件后点“筛选”。条件留空表示不限制。' }));

    async function submit() {
      const q = readScreenForm(form);
      storage(s => s.setItem(SCREEN_KEY, JSON.stringify(q)));
      await busy(run, '筛选中…', async () => {
        const res = await api('GET', '/api/v1/market/screen?' +
          new URLSearchParams({ ...q, limit: '100' }).toString());
        if (stale(token)) return;
        results.textContent = '';
        results.append(h('div', { class: 'card-head' },
          h('h2', { text: `${res.matched} 只符合条件` }),
          h('span', { class: 'muted', text: res.rows.length < res.matched ? `显示前 ${res.rows.length} 只` : '' })));
        if (!res.rows.length) {
          results.append(h('p', { class: 'muted', text: '没有符合条件的股票，放宽一些试试。' }));
          return;
        }
        results.append(h('div', { class: 'table-wrap' }, h('table', {},
          h('thead', {}, h('tr', {},
            h('th', { text: '股票' }), h('th', { class: 'r', text: '市值' }),
            h('th', { class: 'r', text: 'PE(TTM)' }), h('th', { class: 'r', text: 'PB' }),
            h('th', { class: 'r', text: 'ROE' }), h('th', { class: 'r', text: '营收同比' }),
            h('th', { class: 'r', text: '净利同比' }), h('th', { class: 'r', text: '毛利率' }),
            h('th', { class: 'r', text: '现金流/EPS' }), h('th', { text: '' }))),
          h('tbody', {}, res.rows.map(r => screenRow(r))))));
        results.append(h('p', { class: 'muted small', text:
          `ROE、同比、毛利率来自 ${res.snapshot.report_period} 年报；估值为 ${res.snapshot.trade_date} 收盘。` +
          '筛选只是缩小范围，具体是否便宜要看个股页里它自己的历史分位和检查清单。' }));
      });
    }

    form.addEventListener('submit', e => { e.preventDefault(); submit(); });
    reset.addEventListener('click', () => {
      form.reset();
      for (const b of form.querySelectorAll('input[name="boards"]')) b.checked = true;
      storage(s => s.removeItem(SCREEN_KEY));
    });

    setView(head, screenTabs(tab), h('section', { class: 'card' }, form), results);
    if (Object.keys(saved).length) submit();
  }

  function watchButton(r) {
    const add = h('button', { class: 'btn btn-small btn-quiet', text: '加入自选' });
    add.addEventListener('click', async e => {
      e.stopPropagation();
      // busy() restores the button when it finishes, so the "added" state is
      // set after it returns, not inside it.
      const added = await busy(add, '…', async () => {
        await api('POST', '/api/v1/watchlist', { code: r.code });
        showStatus(`已加入 ${r.name || r.code}，可在自选里刷新它的完整数据`);
        return true;
      });
      if (added) { add.textContent = '已加入'; add.disabled = true; }
    });
    return add;
  }

  // ── built-in rules: one rule over the whole market ──────────────────────────

  // Each rule's last numbers, for this browser only.
  const RULES_KEY = 'xmoat.rules';
  const SIGNAL_DAYS_KEY = 'xmoat.signals.days';
  // Each rule's last result, for coming back to the tab without another scan.
  const lastScan = {};

  // A count said in weeks may be 8 or 8.4; either reads as written.
  const fmtCount = v => (isNum(v) ? fmtNum(v, Number.isInteger(v) ? 0 : 1) : '—');
  const REGIME_WORD = { bull: '多头', bear: '空头', range: '震荡', unknown: '数据不足' };
  // A gain reads as a change, so it carries its sign.
  const fmtGain = v => (isNum(v) ? (v > 0 ? '+' : '') + fmtPct(v) : '—');

  function ruleCard(rule, token) {
    const savedAll = (() => {
      try { return JSON.parse(storage(s => s.getItem(RULES_KEY)) || '{}'); } catch (e) { return {}; }
    })();
    // Numbers saved for an earlier definition of the rule mean something else
    // now (a 1% "flatness" was an average's slope, not a price range): start
    // from the current defaults instead.
    const kept = savedAll[rule.id];
    const saved = kept && kept.v === rule.version ? kept.q || {} : {};

    const form = h('form', { class: 'screen-form' });
    const switches = h('div', { class: 'field' }, h('span', { text: '条件' }), h('div', { class: 'checks-row' }));
    for (const f of rule.fields) {
      if (f.type === 'boolean') {
        const on = saved[f.name] !== undefined ? saved[f.name] === 'true' : !!f.default;
        switches.lastChild.append(h('label', { class: 'check' },
          h('input', { type: 'checkbox', name: f.name, checked: on }), h('span', { text: f.label })));
        continue;
      }
      form.append(h('label', { class: 'field' },
        h('span', { text: `${f.label}（${f.unit}）` }),
        h('input', { type: 'number', step: 'any', name: f.name, min: f.min, max: f.max,
          required: true, value: saved[f.name] ?? f.default })));
    }
    if (switches.lastChild.childNodes.length) form.append(switches);
    const run = h('button', { class: 'btn btn-primary', type: 'submit', text: '筛选全市场' });
    const reset = h('button', { class: 'btn btn-quiet', type: 'button', text: '恢复默认' });
    form.append(h('div', { class: 'field field-actions' }, run, reset,
      h('span', { class: 'muted small', text:
        '第一次会用通达信把全市场的日线抓到本地，要一两分钟；之后只补新的几天，十几秒。' })));

    const results = h('section', { class: 'card' });
    const last = lastScan[rule.id];
    if (last) showScan(results, last.res, last.at);
    else results.append(h('p', { class: 'muted', text:
      '点“筛选全市场”，在全部 A 股（不含 ST）里找刚刚首次突破的股票。用默认参数时，结果会记进下面的信号记录。' }));

    const record = signalsCard(token);

    form.addEventListener('submit', async e => {
      e.preventDefault();
      const q = {};
      for (const f of rule.fields) {
        const el = form.elements[f.name];
        if (f.type === 'boolean') q[f.name] = el.checked ? 'true' : 'false';
        else if (el.value !== '') q[f.name] = el.value;
      }
      savedAll[rule.id] = { v: rule.version, q };
      storage(s => s.setItem(RULES_KEY, JSON.stringify(savedAll)));
      await busy(run, '全市场扫描中…', async () => {
        const res = await api('GET', '/api/v1/strategy/scan?' + new URLSearchParams(
          { rule: rule.id, universe: 'market', limit: '6000', record: 'true', ...q }).toString());
        lastScan[rule.id] = { res, at: new Date().toISOString() };
        if (stale(token)) return;
        showScan(results, res, lastScan[rule.id].at);
        // New finds, and the latest closes of the old ones, which the scan moved.
        if (res.recorded) record.reload();
      });
    });
    reset.addEventListener('click', () => {
      for (const f of rule.fields) {
        const el = form.elements[f.name];
        if (f.type === 'boolean') el.checked = !!f.default;
        else el.value = f.default;
      }
      delete savedAll[rule.id];
      storage(s => s.setItem(RULES_KEY, JSON.stringify(savedAll)));
    });

    return [
      h('section', { class: 'card' },
        h('div', { class: 'card-head' }, h('h2', { text: rule.title })),
        h('p', { text: rule.summary }),
        form,
        h('p', { class: 'muted small mt', text: rule.basis })),
      results,
      record.node,
    ];
  }

  // The rows beyond this are there, and counted; a table of a thousand rows
  // is not something anyone reads.
  const SCAN_ROWS = 300;

  function showScan(box, res, at) {
    box.textContent = '';
    const p = res.params || {};
    const f = res.fetch || {};
    // One day's window: every hit broke out today, so "since" is nothing yet.
    const since = res.days > 1;
    box.append(h('div', { class: 'card-head' },
      h('h2', { text: `${res.hits.length} 只首次突破` }),
      h('span', { class: 'muted', text:
        `看了 ${res.checked} 只 · 上穿 ${fmtCount(p.ma_weeks)} 周均线` +
        (p.above_pct > 0 ? ` + ${fmtPct(p.above_pct)}` : '') +
        ` · 横盘 ${fmtCount(p.flat_weeks)} 周、振幅 ≤ ${fmtPct(p.flat_max, 0)}` +
        (res.days > 1 ? ` · 最近 ${res.days} 个交易日` : ' · 当日') }),
      h('span', { class: 'spacer' }),
      h('span', { class: 'muted small', text: '扫描于 ' + fmtTime(at) })));
    const rg = res.regime || {};
    const held = res.hits.filter(x => x.held).length;
    box.append(h('p', { class: rg.state === 'bull' ? 'muted' : 'note', text:
      `沪深300（${rg.date || '—'}）：${REGIME_WORD[rg.state] || '—'}` +
      (p.month_up ? '。只列个股月线向上的。' : '。') +
      (held ? `其中 ${held} 只的信号日大盘不在多头，按设置不推送。` : '') }));
    if (!res.hits.length) {
      box.append(h('p', { class: 'muted', text:
        '没有股票刚刚首次突破。可以把“首次突破在最近”放宽到 3–5 个交易日再看。' }));
    } else {
      box.append(h('div', { class: 'table-wrap' }, h('table', { class: 'watch-table' },
        h('thead', {}, h('tr', {},
          h('th', { text: '股票' }), h('th', { text: '信号日' }), h('th', { text: '大盘' }),
          h('th', { class: 'r', text: '收盘' }), h('th', { class: 'r', text: '均线' }),
          h('th', { class: 'r', text: '高出' }), h('th', { class: 'r', text: '横盘振幅' }),
          h('th', { class: 'r', text: '当日涨幅' }),
          since && h('th', { class: 'r', text: '信号日以来' }),
          h('th', { class: 'r', text: '市值' }),
          h('th', { class: 'r', text: 'PE(TTM)' }), h('th', { class: 'r', text: 'ROE' }),
          h('th', { text: '' }))),
        h('tbody', {}, res.hits.slice(0, SCAN_ROWS).map(r => scanRow(r, since))))));
      if (res.hits.length > SCAN_ROWS) {
        box.append(h('p', { class: 'muted small', text:
          `只列出前 ${SCAN_ROWS} 只（最新的信号、高出均线最多的在前）。` }));
      }
    }
    const lines = [];
    if (res.recorded) {
      const rc = res.recorded;
      const sendable = rc.added - (rc.held || 0);
      lines.push(rc.note || (rc.added === 0 ? '都已在信号记录里，没有新的。'
        : `新记入信号记录 ${rc.added} 只` +
          (rc.held ? `，其中 ${rc.held} 只因大盘不在多头不推送` : '') +
          (sendable === 0 ? '。' : rc.pushing ? '；其余的正在推送。' : '；没有配置推送渠道，所以都不推送。')));
    }
    if (isNum(f.total)) {
      lines.push(`行情：本地 ${f.cached} 只，新抓 ${f.fetched} 只` +
        (f.failed && f.failed.length ? `，失败 ${f.failed.length} 只` : '') +
        (isNum(f.ms) ? `，用时 ${fmtNum(f.ms / 1000, 1)} 秒` : '') + '。');
    }
    if (res.skipped && res.skipped.length) {
      lines.push(`跳过 ${res.skipped.length} 只：日线不够长（多是新股）或没有行情。`);
    }
    if (res.note) lines.push(res.note);
    for (const line of lines) box.append(h('p', { class: 'muted small', text: line }));
  }

  function scanRow(r, since) {
    const open = () => { location.hash = '#/stock/' + r.code; };
    return h('tr', { onclick: open, tabindex: '0', onkeydown: e => { if (e.key === 'Enter') open(); } },
      h('td', { class: 'col-name' }, h('span', { class: 'name', text: r.name || r.code }), ' ',
        h('span', { class: 'code', text: r.code }),
        h('span', { class: 'sub', text: r.industry || '' })),
      h('td', { class: 'date', 'data-label': '信号日', text: r.date + (r.bars_ago > 0 ? `（${r.bars_ago} 天前）` : '') }),
      h('td', { 'data-label': '大盘', text: (REGIME_WORD[r.regime] || '—') + (r.held ? '，不推送' : '') }),
      h('td', { class: 'r num', 'data-label': '收盘', text: fmtNum(r.close) }),
      h('td', { class: 'r num', 'data-label': '均线', text: fmtNum(r.ma) }),
      h('td', { class: 'r num', 'data-label': '高出', text: fmtPct(r.above) }),
      h('td', { class: 'r num', 'data-label': '横盘振幅', text: fmtPct(r.width) }),
      h('td', { class: 'r num', 'data-label': '当日涨幅', text: fmtPct(r.day_gain) }),
      since && h('td', { class: 'r num', 'data-label': '信号日以来', text: fmtGain(r.since_pct) }),
      h('td', { class: 'r num', 'data-label': '市值', text: fmtMoney(r.market_cap) }),
      h('td', { class: 'r num', 'data-label': 'PE(TTM)', text: fmtNum(r.pe_ttm, 1) }),
      h('td', { class: 'r num', 'data-label': 'ROE', text: fmtPct(r.roe) }),
      h('td', { class: 'r col-actions' }, watchButton(r)));
  }

  // What the rule found on earlier days, and what became of it. Kept by the
  // engine (signals.list): the daily check adds to it after every close, and
  // so does a scan here at the default numbers.
  const SIGNAL_WINDOWS = [[7, '近一周'], [30, '近一月'], [90, '近三月']];
  const RUN_SOURCE = { daily: '收盘后的检查', web: '网页', manual: '手动运行' };

  function signalsCard(token) {
    const box = h('section', { class: 'card' });
    let days = Number(storage(s => s.getItem(SIGNAL_DAYS_KEY))) || 30;

    async function load() {
      let res;
      try { res = await api('GET', '/api/v1/signals?days=' + days); }
      catch (e) {
        if (stale(token)) return;
        box.textContent = '';
        box.append(h('p', { class: 'muted', text: '信号记录读取失败：' + e.message }));
        return;
      }
      if (stale(token)) return;
      render(res);
    }

    function render(res) {
      box.textContent = '';
      const seg = h('div', { class: 'seg', role: 'group', 'aria-label': '时间范围' });
      for (const [value, label] of SIGNAL_WINDOWS) {
        seg.append(h('button', { type: 'button', text: label, 'aria-pressed': String(days === value),
          onclick: () => {
            days = value;
            storage(s => s.setItem(SIGNAL_DAYS_KEY, String(value)));
            load();
          } }));
      }
      box.append(h('div', { class: 'card-head' },
        h('h2', { text: '信号记录' }),
        h('span', { class: 'muted', text: `${res.total} 只 · 按信号日，新的在前` }),
        h('span', { class: 'spacer' }), seg));

      const run = res.last_run;
      box.append(h('p', { class: 'muted small', text:
        (res.daily ? '每个交易日收盘后的检查会用默认参数跑一遍全市场，新加入的会推送。'
          : '每日自动运行已关闭（SIGNALS_DAILY=0）。') +
        (run ? `上次运行：${fmtTime(run.at)}，${RUN_SOURCE[run.source] || run.source}，` +
          `新增 ${run.added} 只。` : '') }));

      if (!res.items.length) {
        box.append(h('p', { class: 'muted', text:
          '这段时间里还没有记录。用默认参数点一次“筛选全市场”，或者等收盘后的检查。' }));
        return;
      }
      box.append(h('div', { class: 'table-wrap' }, h('table', { class: 'watch-table' },
        h('thead', {}, h('tr', {},
          h('th', { text: '股票' }), h('th', { text: '信号日' }), h('th', { text: '大盘' }),
          h('th', { text: '加入' }),
          h('th', { class: 'r', text: '信号日收盘' }), h('th', { class: 'r', text: '最新' }),
          h('th', { class: 'r', text: '信号日以来' }), h('th', { class: 'r', text: '加入以来' }),
          h('th', { class: 'r', text: 'ROE' }), h('th', { text: '' }))),
        h('tbody', {}, res.items.map(signalRow)))));
      if (res.count < res.total) {
        box.append(h('p', { class: 'muted small', text: `只列出最新的 ${res.count} 只。` }));
      }
    }

    box.append(h('p', { class: 'muted', text: '加载信号记录…' }));
    load();
    return { node: box, reload: load };
  }

  function signalRow(s) {
    const open = () => { location.hash = '#/stock/' + s.code; };
    return h('tr', { onclick: open, tabindex: '0', onkeydown: e => { if (e.key === 'Enter') open(); } },
      h('td', { class: 'col-name' }, h('span', { class: 'name', text: s.name || s.code }), ' ',
        h('span', { class: 'code', text: s.code }),
        h('span', { class: 'sub', text: s.industry || '' })),
      h('td', { class: 'date', 'data-label': '信号日', text: s.signal_date }),
      h('td', { 'data-label': '大盘', text: (REGIME_WORD[s.regime] || '—') + (s.pushed === 'held' ? '，未推送' : '') }),
      h('td', { class: 'date', 'data-label': '加入', text: fmtTime(s.added_at) }),
      h('td', { class: 'r num', 'data-label': '信号日收盘', text: fmtNum(s.signal_close) }),
      h('td', { class: 'r num date', 'data-label': '最新' },
        fmtNum(s.last_close), h('span', { class: 'sub', text: s.last_date || '' })),
      h('td', { class: 'r num', 'data-label': '信号日以来', text: fmtGain(s.since_signal_pct) }),
      h('td', { class: 'r num', 'data-label': '加入以来', text: fmtGain(s.since_added_pct) }),
      h('td', { class: 'r num', 'data-label': 'ROE', text: fmtPct(s.roe) }),
      h('td', { class: 'r col-actions' }, watchButton(s)));
  }

  function screenRow(r) {
    const open = () => { location.hash = '#/stock/' + r.code; };
    const add = watchButton(r);
    const pct = v => (isNum(v) ? fmtPct(v) : '—');
    return h('tr', { onclick: open, tabindex: '0', onkeydown: e => { if (e.key === 'Enter') open(); } },
      h('td', {}, h('span', { class: 'name', text: r.name || r.code }), ' ',
        h('span', { class: 'code', text: r.code }),
        h('span', { class: 'sub', text: r.industry || '' })),
      h('td', { class: 'r num', 'data-label': '市值', text: fmtMoney(r.market_cap) }),
      h('td', { class: 'r num', 'data-label': 'PE(TTM)', text: fmtNum(r.pe_ttm, 1) }),
      h('td', { class: 'r num', 'data-label': 'PB', text: fmtNum(r.pb) }),
      h('td', { class: 'r num', 'data-label': 'ROE', text: pct(r.roe) }),
      h('td', { class: 'r num', 'data-label': '营收同比', text: pct(r.revenue_yoy) }),
      h('td', { class: 'r num', 'data-label': '净利同比', text: pct(r.np_parent_yoy) }),
      h('td', { class: 'r num', 'data-label': '毛利率', text: pct(r.gross_margin) }),
      h('td', { class: 'r num', 'data-label': '现金流/EPS', text: fmtNum(r.ocf_to_eps) }),
      h('td', { class: 'r' }, add));
  }

  // ── alerts ─────────────────────────────────────────────────────────────────

  const KIND = {
    insight: { icon: '🧠', label: '大模型解读' },
    report: { icon: '📄', label: '财报' },
    dividend: { icon: '💰', label: '分红' },
    band: { icon: '🎯', label: '你的区间' },
    percentile: { icon: '📊', label: '估值分位' },
    check: { icon: '🔎', label: '检查清单' },
  };
  const PUSHED = { true: '已推送', false: '待推送', skipped: '未配置推送', failed: '推送失败' };

  function alertItem(e, withStock) {
    const kind = KIND[e.kind] || { icon: '•', label: e.kind };
    const pushed = PUSHED[String(e.pushed)];
    const icon = e.kind === 'check' ? (e.status === 'warn' ? '⚠️' : '✅') : kind.icon;
    return h('li', {},
      h('span', { class: 'kind', 'aria-hidden': 'true', text: icon }),
      h('div', { class: 'head' },
        withStock ? h('a', { class: 'who', href: '#/stock/' + e.code, text: `${e.name || ''} ${e.code}` }) : null,
        h('span', { class: 'what', text: e.title }),
        h('span', { class: 'tag', text: kind.label })),
      h('span', { class: 'when' }, fmtTime(e.created_at), ' ',
        pushed ? h('span', { class: 'tag' + (e.pushed === 'failed' ? ' is-bad' : ''), text: pushed }) : null),
      e.detail ? h('div', { class: 'detail', text: e.detail }) : null);
  }

  // ── review ─────────────────────────────────────────────────────────────────

  const REGIME = {
    bull: '多头（指数在上升的长期均线之上）',
    bear: '空头（指数在下降的长期均线之下）',
    range: '震荡（指数与长期均线方向不一致）',
    unknown: '未知',
  };

  function reviewMarketCard(m) {
    const card = h('section', { class: 'card' });
    card.append(h('div', { class: 'card-head' }, h('h2', { text: '一、大盘' }),
      h('span', { class: 'muted', text: REGIME[(m.regime || {}).state] || '' })));
    card.append(h('div', { class: 'table-wrap mb' }, h('table', {},
      h('thead', {}, h('tr', {},
        h('th', { text: '指数' }), h('th', { class: 'r', text: '收盘' }),
        h('th', { class: 'r', text: '涨跌' }), h('th', { class: 'r', text: '近 250 日分位' }),
        h('th', { class: 'r', text: '距高点' }), h('th', { class: 'r', text: '量能' }))),
      h('tbody', {}, (m.indexes || []).map(ix => h('tr', {},
        h('td', { text: ix.name || ix.code }),
        h('td', { class: 'r num', text: fmtNum(ix.close) }),
        h('td', { class: 'r num', text: fmtPct(ix.change_pct, 2) }),
        h('td', { class: 'r num', text: fmtPct(ix.position_250, 0) }),
        h('td', { class: 'r num', text: fmtPct(ix.from_high, 1) }),
        h('td', { class: 'r num', text: fmtNum(ix.volume_ratio, 2) })))))));
    const rg = m.regime || {};
    card.append(h('ul', { class: 'plain' },
      (rg.reasons || []).map(x => h('li', { class: 'muted small', text: x }))));
    const st = m.stance || {};
    if (st.position) {
      card.append(h('p', {}, h('strong', { text: '机械仓位区间 ' + st.position + '　' }),
        h('span', { text: st.text || '' })));
      card.append(h('p', { class: 'muted small', text: st.note || '' }));
    }
    return card;
  }

  function sectorTable(title, rows, withLeader) {
    return h('div', { class: 'table-wrap mb' }, h('table', {},
      h('thead', {}, h('tr', {},
        h('th', { text: title }), h('th', { class: 'r', text: '涨跌' }),
        h('th', { class: 'r', text: '涨/跌家数' }),
        withLeader ? h('th', { text: '领涨股' }) : null)),
      h('tbody', {}, rows.map(x => h('tr', {},
        h('td', { text: x.name }),
        h('td', { class: 'r num', text: fmtPct(x.change_pct, 2) }),
        h('td', { class: 'r num', text: (x.up || 0) + '/' + (x.down || 0) }),
        withLeader ? h('td', { text: (x.leader || '—') + ' ' + fmtPct(x.leader_change, 1) }) : null)))));
  }

  function reviewStructureCard(s) {
    const card = h('section', { class: 'card' });
    const when = s.fetched_at ? '板块数据 ' + s.fetched_at.slice(0, 16).replace('T', ' ') + ' UTC' : '';
    card.append(h('div', { class: 'card-head' }, h('h2', { text: '二、结构' }),
      h('span', { class: 'muted', text: when })));
    if (s.note) { card.append(h('p', { class: 'muted', text: s.note })); return card; }
    const b = s.breadth || {};
    card.append(h('p', { text: '板块涨跌：' + (b.up || 0) + ' 涨 / ' + (b.down || 0) + ' 跌 / ' +
      (b.flat || 0) + ' 平，共 ' + (s.sector_count || 0) + ' 个行业板块，上涨占 ' + fmtPct(b.ratio, 0) }));
    card.append(sectorTable('领涨板块', s.leaders || [], true),
      sectorTable('领跌板块', s.laggards || [], false));
    card.append(h('p', { class: 'muted small', text: '按板块口径统计：东方财富的细分行业互相重叠，一只股票会出现在多个板块里，所以这里数的是板块，不是公司。' }));
    return card;
  }

  function reviewWatchCard(w) {
    const card = h('section', { class: 'card' });
    card.append(h('div', { class: 'card-head' }, h('h2', { text: '三、自选' }),
      h('span', { class: 'muted', text: (w.count || 0) + ' 只' })));
    if (!w.count) { card.append(h('p', { class: 'muted', text: '自选为空。' })); return card; }
    card.append(h('div', { class: 'table-wrap' }, h('table', {},
      h('thead', {}, h('tr', {},
        h('th', { text: '代码' }), h('th', { text: '名称' }),
        h('th', { class: 'r', text: '收盘' }), h('th', { class: 'r', text: '涨跌' }),
        h('th', { class: 'r', text: '估值分位' }), h('th', { class: 'r', text: '持仓盈亏' }),
        h('th', { class: 'r', text: '警示' }), h('th', { text: '提示' }))),
      h('tbody', {}, (w.rows || []).map(x => h('tr', {},
        h('td', {}, h('a', { href: '#/stock/' + enc(x.code), text: x.code })),
        h('td', { text: x.name || '—' }),
        h('td', { class: 'r num', text: fmtNum(x.close) }),
        h('td', { class: 'r num', text: fmtPct(x.change_pct, 2) }),
        h('td', { class: 'r num', text: fmtPct(x.percentile, 0) }),
        h('td', { class: 'r num', text: isNum(x.profit_pct) ? fmtPct(x.profit_pct, 1) : (x.held ? '已持有' : '—') }),
        h('td', { class: 'r num', text: String(x.warnings || 0) }),
        h('td', {}, (x.flags || []).length
          ? h('span', { class: 'channel-list' }, x.flags.map(f => h('span', { class: 'tag', text: f })))
          : h('span', { class: 'muted', text: '—' }))))))));
    return card;
  }

  async function renderReview(token) {
    document.title = '复盘 · xmoat';
    setView(loading('复盘生成中…'));
    let r;
    try {
      r = await api('GET', '/api/v1/review');
    } catch (e) { if (!stale(token)) setView(errorCard(e, route)); return; }
    if (stale(token)) return;

    const refresh = h('button', { class: 'btn', text: '重新抓取行情' });
    refresh.addEventListener('click', () => busy(refresh, '抓取中…', async () => {
      await api('GET', '/api/v1/review?force=true');
      route();
    }));
    const head = h('div', { class: 'page-head' },
      h('h1', { text: '复盘 ' + (r.as_of || '') }),
      h('span', { class: 'spacer' }), refresh);

    setView(head, reviewMarketCard(r.market || {}), reviewStructureCard(r.structure || {}),
      reviewWatchCard(r.watchlist || {}));
    view.focus({ preventScroll: true });
  }

  async function renderAlerts(token) {
    document.title = '提醒 · xmoat';
    setView(loading());
    let items, channels, schedule;
    try {
      [items, channels, schedule] = await Promise.all([
        api('GET', '/api/v1/alerts?limit=200'),
        api('GET', '/api/v1/notify/channels'),
        api('GET', '/api/v1/schedule'),
      ]);
    } catch (e) { if (!stale(token)) setView(errorCard(e, route)); return; }
    if (stale(token)) return;

    const runBtn = h('button', { class: 'btn btn-primary', text: '立即检查' });
    runBtn.addEventListener('click', () => busy(runBtn, '检查中…', async () => {
      const r = await api('POST', '/api/v1/alerts/run');
      const failed = r.refreshed.filter(x => !x.ok);
      const parts = [`刷新 ${r.refreshed.length} 只，新提醒 ${r.new_events} 条`];
      if (r.push && r.push.sent) parts.push(`已推送 ${r.push.sent} 条`);
      if (failed.length) parts.push('失败：' + failed.map(x => `${x.code} ${x.error.message}`).join('；'));
      showStatus(parts.join('，'), failed.length > 0);
      route();
    }));

    const testBtn = h('button', { class: 'btn', text: '发送测试消息' });
    testBtn.addEventListener('click', () => busy(testBtn, '发送中…', async () => {
      const results = await api('POST', '/api/v1/notify/test');
      showStatus(results.map(r => `${r.name}：${r.ok ? '成功' : r.error}`).join('；'), results.some(r => !r.ok));
    }));

    const head = h('div', { class: 'page-head' },
      h('h1', { text: '提醒' }),
      h('span', { class: 'meta', text: `${items.length} 条` }),
      h('span', { class: 'spacer' }),
      channels.length ? testBtn : null, runBtn);

    const kv = h('dl', { class: 'kv' });
    const row = (k, v) => kv.append(h('dt', { text: k }), h('dd', {}, v));
    row('推送渠道', channels.length
      ? h('span', { class: 'channel-list' }, channels.map(c => h('span', { class: 'tag', text: c.name })))
      : h('span', { class: 'muted', text: '未配置。在 xmoat.local.cfg 里填写企业微信（群机器人或应用）、飞书、钉钉、Telegram 或 Webhook，格式见 xmoat.local.cfg.example。' }));
    if (schedule.enabled) {
      const offset = `UTC${schedule.utc_offset >= 0 ? '+' : ''}${schedule.utc_offset}`;
      row('定时检查', h('span', { text: `星期 ${schedule.weekdays}（1 为周一）的 ${(schedule.times || []).join('、')}（${offset}）` }));
      row('下次检查', h('span', { class: 'num', text: schedule.running ? '正在检查…' : (schedule.next_run || '—') }));
    } else {
      row('定时检查', h('span', { class: 'muted', text: schedule.error ? `配置有误：${schedule.error}` : '未启用（SCHEDULE_ENABLED=0）' }));
    }

    const settings = h('section', { class: 'card' }, h('h2', { text: '推送与定时' }), kv);

    const list = h('section', { class: 'card' });
    if (!items.length) {
      list.append(h('div', { class: 'empty' },
        h('p', { text: '还没有提醒。' }),
        h('p', { class: 'muted', text: '刷新自选股时，出现新财报、新分红方案、估值穿过你设的区间或进入历史高低位、检查清单出现新提示，都会记在这里。' })));
    } else {
      let day = null;
      let ul = null;
      for (const e of items) {
        const d = fmtTime(e.created_at).slice(0, 10);
        if (d !== day) {
          day = d;
          list.append(h('div', { class: 'day-head', text: d }));
          ul = h('ul', { class: 'alerts' });
          list.append(ul);
        }
        ul.append(alertItem(e, true));
      }
    }
    setView(head, settings, list);
  }

  // Loaded after the rest of the page: the analysis stands without it.
  function recentAlertsCard(code, token) {
    const card = h('section', { class: 'card', hidden: true });
    api('GET', `/api/v1/alerts?code=${enc(code)}&limit=10`).then(items => {
      if (stale(token) || !items.length) return;
      card.append(
        h('div', { class: 'card-head' }, h('h2', { text: '最近提醒' }), h('span', { class: 'spacer' }),
          h('a', { href: '#/alerts', text: '全部提醒' })),
        h('ul', { class: 'alerts' }, items.map(e => alertItem(e, false))));
      card.hidden = false;
    }).catch(() => {});
    return card;
  }

  function sourcesLine(a) {
    const items = (a.sources || []).map(s => s.item).filter(Boolean);
    return h('p', { class: 'muted small', text: `数据来源：东方财富（${items.join('、')}），获取于 ${fmtTime(a.fetched_at)}。` });
  }

  // ── adding a stock ─────────────────────────────────────────────────────────

  const addForm = document.getElementById('add-form');
  addForm.addEventListener('submit', e => {
    e.preventDefault();
    const input = document.getElementById('add-code');
    const button = addForm.querySelector('button');
    const code = input.value.trim();
    if (!code) return;
    busy(button, '…', async () => {
      let entry;
      try {
        entry = await api('POST', '/api/v1/watchlist', { code });
      } catch (err) {
        if (err.code !== 'conflict') throw err;
        showStatus(err.message);
        return;
      }
      input.value = '';
      showStatus(`已加入 ${entry.code}，正在获取数据…首次抓取完整历史可能需要一分钟`);
      try {
        await api('POST', `/api/v1/stocks/${enc(entry.code)}/refresh`);
        clearStatus();
      } catch (err) {
        showStatus(`${entry.code} 已加入自选，但获取数据失败：${err.message}`, true);
      }
      const target = '#/stock/' + entry.code;
      if (location.hash === target) route();
      else location.hash = target;   // hashchange routes
    });
  });

  window.addEventListener('hashchange', route);
  route();
})();
