// chart.js — one line chart: a valuation metric over time.
//
// Hand-written SVG rather than a charting library: the page loads nothing from
// outside its own origin (the CSP says so), and the chart it needs is one
// series with a reference line and a shaded band.
//
// Rules this keeps (see the data-viz method it was built against):
//   * one series, one axis, so no legend — the card title names the metric
//   * 2px line, hairline solid grid, an end dot ringed in the surface color
//   * a crosshair that snaps to the nearest day, with the value leading the
//     tooltip; arrow keys do the same for keyboard users
//   * every string goes in with textContent, and every value shown on hover is
//     also in the table the page offers beside the chart
(function () {
  'use strict';

  const SVG = 'http://www.w3.org/2000/svg';

  function el(name, attrs, parent) {
    const node = document.createElementNS(SVG, name);
    for (const k in attrs || {}) node.setAttribute(k, attrs[k]);
    if (parent) parent.appendChild(node);
    return node;
  }

  // Round-number ticks spanning [lo, hi].
  function niceTicks(lo, hi, count) {
    if (!(hi > lo)) { hi = lo + 1; }
    const raw = (hi - lo) / Math.max(1, count);
    const mag = Math.pow(10, Math.floor(Math.log10(raw)));
    const norm = raw / mag;
    const step = (norm < 1.5 ? 1 : norm < 3 ? 2 : norm < 7 ? 5 : 10) * mag;
    const start = Math.floor(lo / step) * step;
    const ticks = [];
    for (let v = start; v <= hi + step * 0.5; v += step) ticks.push(+v.toFixed(10));
    return ticks;
  }

  // opts: { points: [[date, value|null]], format(v), median, band: {low, high},
  //         height, ariaLabel }
  function line(container, opts) {
    const points = (opts.points || []).filter(p => Array.isArray(p));
    const fmt = opts.format || (v => String(v));
    container.textContent = '';
    container.classList.add('chart');

    const values = points.map(p => (typeof p[1] === 'number' ? p[1] : null));
    const present = values.filter(v => v !== null);
    if (present.length < 2) {
      const empty = document.createElement('p');
      empty.className = 'muted';
      empty.textContent = '数据不足，画不出走势。';
      container.appendChild(empty);
      return { destroy() {} };
    }

    const tooltip = document.createElement('div');
    tooltip.className = 'tooltip';
    tooltip.hidden = true;

    let hoverIndex = null;
    let observer = null;

    function render() {
      const width = Math.max(280, container.clientWidth || 600);
      const height = opts.height || (width < 520 ? 200 : 260);
      const m = { top: 14, right: 62, bottom: 26, left: 44 };
      const iw = width - m.left - m.right;
      const ih = height - m.top - m.bottom;

      let lo = Math.min(...present), hi = Math.max(...present);
      const extras = [opts.median, opts.band && opts.band.low, opts.band && opts.band.high]
        .filter(v => typeof v === 'number');
      for (const v of extras) { lo = Math.min(lo, v); hi = Math.max(hi, v); }
      const pad = (hi - lo) * 0.06 || Math.abs(hi) * 0.1 || 1;
      const ticks = niceTicks(lo - pad, hi + pad, width < 520 ? 4 : 5);
      const y0 = ticks[0], y1 = ticks[ticks.length - 1];
      // Ticks are round numbers, so they get only the decimals their step has:
      // "70", not "70.0".
      const tickStep = ticks.length > 1 ? ticks[1] - ticks[0] : 1;
      const tickDigits = Math.max(0, Math.min(3, -Math.floor(Math.log10(tickStep) + 1e-9)));
      const tickFmt = t => t.toLocaleString('zh-CN', { minimumFractionDigits: tickDigits, maximumFractionDigits: tickDigits });
      const x = i => m.left + (points.length === 1 ? iw / 2 : (i / (points.length - 1)) * iw);
      const y = v => m.top + ih - ((v - y0) / (y1 - y0)) * ih;

      container.textContent = '';
      const svg = el('svg', {
        viewBox: `0 0 ${width} ${height}`, width, height, role: 'img', tabindex: '0',
        'aria-label': opts.ariaLabel || '走势图',
      }, container);

      // Grid and y ticks.
      const grid = el('g', { class: 'grid' }, svg);
      const axis = el('g', { class: 'axis' }, svg);
      for (const t of ticks) {
        el('line', { x1: m.left, x2: m.left + iw, y1: y(t), y2: y(t) }, grid);
        const label = el('text', { x: m.left - 8, y: y(t) + 4, 'text-anchor': 'end' }, axis);
        label.textContent = tickFmt(t);
      }

      // x ticks at year boundaries, thinned so labels never collide.
      const years = [];
      for (let i = 0; i < points.length; i++) {
        const yr = String(points[i][0]).slice(0, 4);
        if (i === 0 || yr !== String(points[i - 1][0]).slice(0, 4)) years.push({ i, yr });
      }
      const minGap = 44;
      let lastX = -Infinity;
      for (const { i, yr } of years) {
        const px = x(i);
        if (px - lastX < minGap || px > m.left + iw - 16) continue;
        const t = el('text', { x: px, y: height - 6, 'text-anchor': i === 0 ? 'start' : 'middle' }, axis);
        t.textContent = yr;
        lastX = px;
      }
      el('line', { class: 'baseline', x1: m.left, x2: m.left + iw, y1: m.top + ih, y2: m.top + ih }, svg);

      // The user's band, as a wash behind everything.
      const band = opts.band;
      if (band && (typeof band.low === 'number' || typeof band.high === 'number')) {
        const top = y(typeof band.high === 'number' ? band.high : y1);
        const bottom = y(typeof band.low === 'number' ? band.low : y0);
        el('rect', { class: 'band', x: m.left, y: top, width: iw, height: Math.max(0, bottom - top) }, svg);
      }

      // Historical median, labelled once at its left end.
      if (typeof opts.median === 'number') {
        el('line', { class: 'ref', x1: m.left, x2: m.left + iw, y1: y(opts.median), y2: y(opts.median) }, svg);
        const t = el('text', { class: 'ref-label', x: m.left + 4, y: y(opts.median) - 5 }, svg);
        t.textContent = '中位数 ' + fmt(opts.median);
      }

      // The series, broken where a day has no value.
      let d = '';
      let pen = false;
      values.forEach((v, i) => {
        if (v === null) { pen = false; return; }
        d += (pen ? 'L' : 'M') + x(i).toFixed(1) + ' ' + y(v).toFixed(1);
        pen = true;
      });
      el('path', { class: 'line', d }, svg);

      // End dot and the one direct label: today's value.
      let last = values.length - 1;
      while (last > 0 && values[last] === null) last--;
      el('circle', { class: 'end-dot', cx: x(last), cy: y(values[last]), r: 4 }, svg);
      const endLabel = el('text', { class: 'end-label', x: x(last) + 8, y: y(values[last]) + 4 }, svg);
      endLabel.textContent = fmt(values[last]);

      // Hover layer.
      const cross = el('line', { class: 'cross', y1: m.top, y2: m.top + ih, visibility: 'hidden' }, svg);
      const dot = el('circle', { class: 'hover-dot', r: 4, visibility: 'hidden' }, svg);
      const hit = el('rect', { class: 'hit', x: m.left, y: m.top, width: iw, height: ih }, svg);
      container.appendChild(tooltip);

      function show(i) {
        if (i === null) {
          cross.setAttribute('visibility', 'hidden');
          dot.setAttribute('visibility', 'hidden');
          tooltip.hidden = true;
          return;
        }
        hoverIndex = i;
        const px = x(i);
        cross.setAttribute('x1', px); cross.setAttribute('x2', px);
        cross.setAttribute('visibility', 'visible');
        const v = values[i];
        if (v === null) { dot.setAttribute('visibility', 'hidden'); }
        else {
          dot.setAttribute('cx', px); dot.setAttribute('cy', y(v));
          dot.setAttribute('visibility', 'visible');
        }
        tooltip.textContent = '';
        const vEl = document.createElement('div');
        vEl.className = 'v';
        vEl.textContent = v === null ? '—' : fmt(v);
        const dEl = document.createElement('div');
        dEl.className = 'd';
        dEl.textContent = String(points[i][0]);
        tooltip.append(vEl, dEl);
        tooltip.hidden = false;
        const scale = container.clientWidth / width;
        const left = px * scale;
        const tw = tooltip.offsetWidth;
        tooltip.style.left = Math.min(Math.max(0, left - tw / 2), container.clientWidth - tw) + 'px';
        // Above the point when there is room, otherwise below it, so the tooltip
        // never sits on the value it describes.
        const py = (v === null ? m.top : y(v)) * scale;
        const above = py - tooltip.offsetHeight - 12;
        tooltip.style.top = (above >= 0 ? above : py + 12) + 'px';
      }

      function indexAt(evt) {
        const rect = svg.getBoundingClientRect();
        const px = (evt.clientX - rect.left) * (width / rect.width);
        const i = Math.round(((px - m.left) / iw) * (points.length - 1));
        return Math.min(points.length - 1, Math.max(0, i));
      }

      hit.addEventListener('pointermove', e => show(indexAt(e)));
      hit.addEventListener('pointerdown', e => show(indexAt(e)));
      hit.addEventListener('pointerleave', () => show(null));
      svg.addEventListener('blur', () => show(null));
      svg.addEventListener('keydown', e => {
        const step = e.shiftKey ? 20 : 1;
        let i = hoverIndex === null ? last : hoverIndex;
        if (e.key === 'ArrowLeft') i = Math.max(0, i - step);
        else if (e.key === 'ArrowRight') i = Math.min(points.length - 1, i + step);
        else if (e.key === 'Home') i = 0;
        else if (e.key === 'End') i = points.length - 1;
        else if (e.key === 'Escape') { show(null); return; }
        else return;
        e.preventDefault();
        show(i);
      });
    }

    render();
    if (typeof ResizeObserver === 'function') {
      let lastWidth = container.clientWidth;
      observer = new ResizeObserver(() => {
        if (Math.abs(container.clientWidth - lastWidth) < 2) return;
        lastWidth = container.clientWidth;
        hoverIndex = null;
        render();
      });
      observer.observe(container);
    }
    return { destroy() { if (observer) observer.disconnect(); } };
  }

  window.XmoatChart = { line };
})();
