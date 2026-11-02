/**
 * Public, browser-only curve-to-contour visualization for /dashboard#math.
 * This is NOT an algebraic isogeny verifier and does not submit math jobs.
 * The curve generates real drawing primitives; a finite DFT reconstructs them.
 */
const TAU = Math.PI * 2;
const MAX_ORDER = 80;
const SOURCE_SAMPLES = 800;
const MAX_CURVE_Y = Math.sqrt(16 / (3 * Math.sqrt(3)));
const EMPTY_CONTROLLER = Object.freeze({setVisible() {}, dispose() {}});

/** Parameterization of the bounded REAL oval on E: y² = x³ - 4x. */
export function realOvalPoint(t) {
  const x = -1 + Math.cos(t);
  const y = (Math.sin(t) >= 0 ? 1 : -1) * Math.sqrt(Math.max(0, x ** 3 - 4 * x));
  return {x, y};
}

function normalizedOval(count) {
  return Array.from({length: count}, (_, i) => {
    const {x, y} = realOvalPoint(Math.PI + TAU * i / count);
    return {x: x + 1, y: y / MAX_CURVE_Y};
  });
}

function transformWing(root, tip, width, count = 108) {
  const ax = tip[0] - root[0], ay = tip[1] - root[1];
  const length = Math.hypot(ax, ay);
  const nx = -ay / length, ny = ax / length;
  return normalizedOval(count).map(({x: a, y: b}) => {
    const longitudinal = (1 + a) / 2;
    const transverse = b * width * (.92 + .12 * a);
    return {x: root[0] + ax * longitudinal + nx * transverse,
            y: root[1] + ay * longitudinal + ny * transverse};
  });
}

function ellipse(cx, cy, rx, ry, count = 90) {
  return Array.from({length: count}, (_, i) => {
    const t = TAU * i / count;
    return {x: cx + rx * Math.cos(t), y: cy + ry * Math.sin(t)};
  });
}

function dragonflyContour() {
  const wings = [
    [[-.12, -.13], [-2.28, -1.1], .39],
    [[ .12, -.13], [ 2.28, -1.1], .39],
    [[-.12,  .07], [-2.21,  .70], .45],
    [[ .12,  .07], [ 2.21,  .70], .45]
  ];
  const points = wings.flatMap(([root, tip, width]) => transformWing(root, tip, width));
  points.push(...ellipse(0, -.36, .16, .19, 58)); // head
  points.push(...ellipse(0, .09, .23, .35, 70));  // thorax
  for (let i = 0; i <= 58; i++) {
    const q = i / 58;
    points.push({x: .115 * (1 - .73 * q) + .012 * Math.sin(q * TAU * 4), y: .32 + 1.8 * q});
  }
  for (let i = 58; i >= 0; i--) {
    const q = i / 58;
    points.push({x: -.115 * (1 - .73 * q) - .012 * Math.sin(q * TAU * 4), y: .32 + 1.8 * q});
  }
  return points;
}

function flowerContour() {
  const points = [];
  for (let i = 0; i < 6; i++) {
    const angle = i * TAU / 6, cos = Math.cos(angle), sin = Math.sin(angle);
    points.push(...transformWing([.14 * cos, .14 * sin], [1.95 * cos, 1.95 * sin], .48, 118));
  }
  return points.concat(ellipse(0, 0, .23, .23, 75));
}

export function imageContour(kind) {
  if (kind === 'dragonfly') return dragonflyContour();
  if (kind === 'flower') return flowerContour();
  if (kind === 'oval') return normalizedOval(640).map(p => ({x: p.x * 1.7, y: p.y * 1.7}));
  throw Error('Unknown illustration: ' + kind);
}

/** Equidistant arc-length samples along a closed, piecewise linear contour. */
export function resampleContour(points, count) {
  if (!points.length || !Number.isInteger(count) || count <= 0) throw Error('Invalid contour');
  const closed = [...points, points[0]], lengths = [0];
  for (let i = 1; i < closed.length; i++) {
    lengths.push(lengths[i - 1] + Math.hypot(closed[i].x - closed[i - 1].x,
                                              closed[i].y - closed[i - 1].y));
  }
  const total = lengths[lengths.length - 1];
  if (total === 0) throw Error('Degenerate contour');
  let index = 0;
  return Array.from({length: count}, (_, j) => {
    const distance = j * total / count;
    while (index < lengths.length - 2 && lengths[index + 1] < distance) index++;
    const portion = (distance - lengths[index]) / (lengths[index + 1] - lengths[index] || 1);
    return {x: closed[index].x + (closed[index + 1].x - closed[index].x) * portion,
            y: closed[index].y + (closed[index + 1].y - closed[index].y) * portion};
  });
}

/** c_k = (1/M) sum_j z_j exp(-2πikj/M), indexed from -order to +order. */
export function fourierCoefficients(samples, order = MAX_ORDER) {
  if (!samples.length) throw Error('No samples');
  const coefficients = new Map(), inv = 1 / samples.length;
  for (let k = -order; k <= order; k++) {
    let re = 0, im = 0;
    for (let j = 0; j < samples.length; j++) {
      const theta = -TAU * k * j * inv, cos = Math.cos(theta), sin = Math.sin(theta);
      re += samples[j].x * cos - samples[j].y * sin;
      im += samples[j].x * sin + samples[j].y * cos;
    }
    coefficients.set(k, {re: re * inv, im: im * inv});
  }
  return coefficients;
}

/** z_N(t) = sum_{k=-N}^N c_k exp(2πikt). */
export function fourierPoint(coefficients, t, order) {
  let x = 0, y = 0;
  for (let k = -order; k <= order; k++) {
    const c = coefficients.get(k);
    if (!c) throw Error('Missing Fourier coefficient ' + k);
    const theta = TAU * k * t, cos = Math.cos(theta), sin = Math.sin(theta);
    x += c.re * cos - c.im * sin;
    y += c.re * sin + c.im * cos;
  }
  return {x, y};
}

function fitCanvas(canvas, context) {
  const {width: w, height: h} = canvas.getBoundingClientRect();
  if (w <= 0 || h <= 0) return null;
  const ratio = Math.min(window.devicePixelRatio || 1, 2);
  const pixelsW = Math.round(w * ratio), pixelsH = Math.round(h * ratio);
  if (canvas.width !== pixelsW || canvas.height !== pixelsH) {
    canvas.width = pixelsW; canvas.height = pixelsH;
  }
  context.setTransform(ratio, 0, 0, ratio, 0, 0);
  return {w, h};
}

function stroke(ctx, points, color, width = 1, closed = false) {
  if (!points.length) return;
  ctx.beginPath();ctx.moveTo(points[0].x, points[0].y);
  for (let i = 1; i < points.length; i++) ctx.lineTo(points[i].x, points[i].y);
  if (closed) ctx.closePath();
  ctx.strokeStyle = color;ctx.lineWidth = width;ctx.stroke();
}

function ring(ctx, x, y, radius, color, width = 1) {
  ctx.beginPath();ctx.arc(x, y, radius, 0, TAU);
  ctx.lineWidth = width;ctx.strokeStyle = color;ctx.stroke();
}

/** A controller following the console's setVisible / dispose lifecycle. */
export function initMathKernel() {
  if (typeof document === 'undefined') return EMPTY_CONTROLLER;
  const root = document.getElementById('mathKernel');
  if (!root) return EMPTY_CONTROLLER;
  const $ = id => root.querySelector('#' + id);
  const stage = $('mathKernelStage'), curve = $('mathKernelCurve'), spectrum = $('mathKernelSpectrum');
  const stageCtx = stage?.getContext('2d'), curveCtx = curve?.getContext('2d'), spectrumCtx = spectrum?.getContext('2d');
  if (!stageCtx || !curveCtx || !spectrumCtx) return EMPTY_CONTROLLER;
  const terms = $('mathKernelTerms'), speed = $('mathKernelSpeed'), shape = $('mathKernelShape');
  const auto = $('mathKernelAuto'), play = $('mathKernelPlay');
  const abort = new AbortController(), curvePlot = [];
  for (let i = 0; i <= 500; i++) curvePlot.push(realOvalPoint(TAU * i / 500));

  let source = [], coeffs = new Map(), trace = [], order = 12;
  let elapsed = 0, passes = 0, visible = false, onscreen = true, disposed = false;
  let playing = !window.matchMedia?.('(prefers-reduced-motion: reduce)').matches;
  let frameId = 0, lastFrame = 0;
  const clockRate = 13.5; // seconds per trace at 1×

  function rebuildTrace() {
    trace = Array.from({length: 431}, (_, i) => fourierPoint(coeffs, i / 430, order));
    $('mathKernelTermsLabel').textContent = String(order);
    terms.value = String(order);
  }

  function chooseShape() {
    source = resampleContour(imageContour(shape.value), SOURCE_SAMPLES);
    coeffs = fourierCoefficients(source);
    order = Number(terms.value);
    rebuildTrace(); elapsed = 0; passes = 0;
    drawAll();
  }

  function drawStage() {
    const size = fitCanvas(stage, stageCtx);
    if (!size) return;
    const {w, h} = size, ctx = stageCtx, mobile = w < 660;
    const left = {x: w * (mobile ? .5 : .255), y: mobile ? h * .225 : h * .52};
    const right = {x: w * (mobile ? .5 : .742), y: mobile ? h * .695 : h * .52};
    const scale = mobile ? Math.min(w * .158, h * .102) : Math.min(w * .085, h * .165);
    ctx.clearRect(0, 0, w, h);
    ctx.strokeStyle = '#183040';ctx.lineWidth = .6;
    for (let x = 0; x < w; x += 34) {ctx.beginPath();ctx.moveTo(x, 0);ctx.lineTo(x, h);ctx.stroke();}
    for (let y = 0; y < h; y += 34) {ctx.beginPath();ctx.moveTo(0, y);ctx.lineTo(w, y);ctx.stroke();}
    ctx.fillStyle = '#94b3c4';ctx.font = '600 11px ui-monospace, monospace';
    ctx.fillText('01 / ROTATING VECTORS', 12, 21);
    ctx.fillText('02 / CURVE-DERIVED IMAGE', mobile ? 12 : w * .52, mobile ? h * .475 : 21);
    ctx.save();ctx.setLineDash([3, 8]);
    ring(ctx, left.x, left.y, scale * 1.95, '#2a4454');
    ring(ctx, right.x, right.y, scale * 2.55, '#1a3441');ctx.restore();
    const toRight = p => ({x: right.x + p.x * scale, y: right.y + p.y * scale});
    stroke(ctx, source.map(toRight), '#43616c', 1, true);
    if (shape.value === 'dragonfly') {
      ctx.strokeStyle = '#234757';ctx.lineWidth = .75;
      for (const sign of [-1, 1]) for (let q = 0; q < 4; q++) {
        const wingY = [-.7, -.43, .3, .47][q], tx = (q < 2 ? 2 : 1.8) * sign;
        const ty = q < 2 ? -.9 : .53;
        const p0 = {x: right.x + sign * .13 * scale, y: right.y + (q < 2 ? -.13 : .07) * scale};
        const p1 = {x: right.x + tx * (.47 + .08 * q) * scale,
                    y: right.y + (ty * .7 + wingY * .2) * scale};
        ctx.beginPath();ctx.moveTo(p0.x, p0.y);
        ctx.quadraticCurveTo(right.x + sign * .9 * scale, right.y + wingY * scale, p1.x, p1.y);
        ctx.stroke();
      }
    }

    const fraction = elapsed % 1;
    const drawn = Math.floor(430 * fraction);
    if (drawn > 0) {
      const partial = trace.slice(0, drawn + 1).map(toRight);
      ctx.shadowColor = '#7fdbe2';ctx.shadowBlur = 13;
      stroke(ctx, partial, '#70e8e9', 2.4);ctx.shadowBlur = 0;
      stroke(ctx, partial, '#edffff', .7);
    }
    // The rotating chain exactly computes the current finite Fourier sum.
    const sequence = [0];
    for (let k = 1; k <= order; k++) sequence.push(k, -k);
    let origin = {x: left.x, y: left.y};
    for (let j = 0; j < sequence.length; j++) {
      const k = sequence[j], c = coeffs.get(k), theta = TAU * k * fraction;
      const cos = Math.cos(theta), sin = Math.sin(theta);
      const dx = (c.re * cos - c.im * sin) * scale;
      const dy = (c.re * sin + c.im * cos) * scale;
      const next = {x: origin.x + dx, y: origin.y + dy};
      const radius = Math.hypot(c.re, c.im) * scale;
      if (radius > .65 && j < 58) ring(ctx, origin.x, origin.y, radius, j < 11 ? '#bd9a73a3' : '#7994a052', j < 10 ? 1.05 : .65);
      if (j < 42 && radius > 1) {
        ctx.strokeStyle = j < 11 ? '#f8c078' : '#6d8a9c';ctx.lineWidth = j < 8 ? 1.5 : .9;
        ctx.beginPath();ctx.moveTo(origin.x, origin.y);ctx.lineTo(next.x, next.y);ctx.stroke();
      }
      origin = next;
    }
    const target = toRight(fourierPoint(coeffs, fraction, order));
    ctx.save();ctx.setLineDash([6, 9]);ctx.strokeStyle = '#ddaf6f8f';ctx.lineWidth = 1.4;
    ctx.beginPath();ctx.moveTo(origin.x, origin.y);ctx.lineTo(target.x, target.y);ctx.stroke();ctx.restore();
    for (const {point, color} of [{point: origin, color: '#fbd18a'}, {point: target, color: '#85f6f9'}]) {
      ctx.shadowColor = color;ctx.shadowBlur = 16;ctx.fillStyle = color;
      ctx.beginPath();ctx.arc(point.x, point.y, 3.9, 0, TAU);ctx.fill();ctx.shadowBlur = 0;
    }
    ctx.font = '12px ui-monospace, monospace';ctx.fillStyle = '#9ab4c1';
    ctx.fillText('t = ' + fraction.toFixed(3), Math.max(12, left.x - scale * 1.7), left.y + scale * 2.58);
    ctx.fillText('N = ' + order + '  ·  PASS ' + (passes + 1), Math.max(12, right.x - scale * 2.3), right.y + scale * 2.8);
    ctx.fillText(Math.round(fraction * 100) + '% traced', Math.max(12, right.x - scale * 2.3), right.y + scale * 3.1);
  }

  function drawCurve() {
    const size = fitCanvas(curve, curveCtx);
    if (!size) return;
    const {w, h} = size, ctx = curveCtx;
    ctx.clearRect(0, 0, w, h);
    const l = 24, r = w - 24, top = 12, bottom = h - 16;
    const xMap = x => l + (x + 2.38) / 2.8 * (r - l);
    const yMap = y => top + (2.18 - y) / 4.36 * (bottom - top);
    ctx.strokeStyle = '#597184';ctx.lineWidth = .65;
    ctx.beginPath();ctx.moveTo(xMap(0), top);ctx.lineTo(xMap(0), bottom);
    ctx.moveTo(l, yMap(0));ctx.lineTo(r, yMap(0));ctx.stroke();
    stroke(ctx, curvePlot.map(p => ({x: xMap(p.x), y: yMap(p.y)})), '#1199ad', 1.75, true);
    const point = realOvalPoint(TAU * elapsed);
    ctx.shadowColor = '#dfae68';ctx.shadowBlur = 12;ctx.fillStyle = '#e4a34d';
    ctx.beginPath();ctx.arc(xMap(point.x), yMap(point.y), 4.5, 0, TAU);ctx.fill();ctx.shadowBlur = 0;
    ctx.fillStyle = '#ae69ca';ctx.beginPath();ctx.arc(xMap(0), yMap(0), 2.8, 0, TAU);ctx.fill();
    ctx.fillStyle = '#8da1b2';ctx.font = '11px monospace';ctx.fillText('(0,0)', xMap(0) + 7, yMap(0) - 7);
    $('mathKernelPoint').textContent = 'P = (' + point.x.toFixed(2) + ', ' + point.y.toFixed(2) + ')';
  }

  function drawSpectrum() {
    const size = fitCanvas(spectrum, spectrumCtx);
    if (!size) return;
    const {w, h} = size, ctx = spectrumCtx;
    ctx.clearRect(0, 0, w, h);
    const padding = 12, usableW = w - padding * 2, usableH = h - 18;
    const magnitudes = Array.from({length: MAX_ORDER * 2 + 1}, (_, i) => {
      const c = coeffs.get(i - MAX_ORDER);
      return Math.hypot(c.re, c.im);
    });
    const peak = Math.max(...magnitudes, 1e-6);
    ctx.strokeStyle = '#718396';ctx.beginPath();ctx.moveTo(padding, h - 8);ctx.lineTo(w - padding, h - 8);ctx.stroke();
    for (let i = 0; i < magnitudes.length; i++) {
      const k = i - MAX_ORDER, x = padding + i / magnitudes.length * usableW;
      const height = Math.min(usableH - 6, Math.sqrt(magnitudes[i] / peak) * (usableH - 7));
      ctx.fillStyle = Math.abs(k) <= order ? (k === 0 ? '#dfae68' : '#179eac') : '#a8b5c1';
      ctx.fillRect(x, h - 8 - height, Math.max(1.1, usableW / magnitudes.length - .3), height);
    }
    ctx.font = '10px monospace';ctx.fillStyle = '#7892a1';
    ctx.fillText('−80', padding, 11);ctx.fillText('0', w / 2 - 3, 11);ctx.fillText('+80', w - padding - 26, 11);
  }

  function drawAll() {
    if (!visible || !coeffs.size || disposed) return;
    drawStage();drawCurve();drawSpectrum();
  }

  function frame(time) {
    frameId = 0;
    if (disposed || !visible || !playing || document.hidden || !onscreen) return;
    if (!lastFrame) lastFrame = time;
    const dt = Math.min((time - lastFrame) / 1000, .08);
    lastFrame = time;
    elapsed += dt * Number(speed.value) / clockRate;
    if (elapsed >= 1) {
      passes += Math.floor(elapsed);elapsed %= 1;
      if (auto.checked && order < MAX_ORDER) {
        order = Math.min(MAX_ORDER, order + 4);
        rebuildTrace();drawSpectrum();
      }
    }
    drawStage();drawCurve();
    frameId = requestAnimationFrame(frame);
  }

  function syncAnimation() {
    const active = visible && onscreen && !document.hidden && playing && !disposed;
    root.dataset.animating = active ? 'true' : 'false';
    play.textContent = playing ? 'Pause' : 'Play';
    play.setAttribute('aria-pressed', String(playing));
    if (!active) {
      if (frameId) cancelAnimationFrame(frameId);
      frameId = 0;lastFrame = 0;
    } else if (!frameId) {
      lastFrame = 0;
      frameId = requestAnimationFrame(frame);
    }
  }

  terms.addEventListener('input', () => {order = Number(terms.value);rebuildTrace();drawAll();}, {signal: abort.signal});
  speed.addEventListener('input', () => {
    $('mathKernelSpeedLabel').textContent = Number(speed.value).toFixed(2).replace(/\.?0+$/, '') + '×';
  }, {signal: abort.signal});
  shape.addEventListener('change', chooseShape, {signal: abort.signal});
  play.addEventListener('click', () => {playing = !playing;syncAnimation();}, {signal: abort.signal});
  $('mathKernelReset').addEventListener('click', () => {
    elapsed = 0;passes = 0;order = 12;rebuildTrace();drawAll();
  }, {signal: abort.signal});
  document.addEventListener('visibilitychange', syncAnimation, {signal: abort.signal});
  const observer = typeof IntersectionObserver === 'function' ? new IntersectionObserver(entries => {
    onscreen = Boolean(entries[0]?.isIntersecting);syncAnimation();
  }, {threshold: 0}) : null;
  observer?.observe(root);
  const resize = typeof ResizeObserver === 'function' ? new ResizeObserver(drawAll) : null;
  resize?.observe(stage);resize?.observe(curve);resize?.observe(spectrum);
  window.addEventListener('resize', drawAll, {signal: abort.signal});

  return {
    setVisible(value) {
      if (disposed) return;
      visible = Boolean(value);
      if (visible && !coeffs.size) chooseShape();
      if (visible) drawAll();
      syncAnimation();
    },
    dispose() {
      if (disposed) return;
      disposed = true;syncAnimation();abort.abort();observer?.disconnect();resize?.disconnect();
    }
  };
}
