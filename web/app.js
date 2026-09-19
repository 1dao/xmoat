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
    const page = m ? 'stock' : location.hash === '#/alerts' ? 'alerts' : 'watchlist';
    for (const link of document.querySelectorAll('[data-nav]')) {
      if (link.dataset.nav === page) link.setAttribute('aria-current', 'page');
      else link.removeAttribute('aria-current');
    }
    if (m) return renderStock(m[1], token);
    if (page === 'alerts') return renderAlerts(token);
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
      qualityCard(a),
      businessCard(a),
      dividendCard(a),
      checksCard(a),
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

    tiles.append(bandTile(a));
    card.append(tiles);
    return card;
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
      : h('span', { class: 'muted', text: '未配置。在 xmoat.local.cfg 里填写企业微信、飞书、钉钉、Telegram 或 Webhook，格式见 xmoat.local.cfg.example。' }));
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
