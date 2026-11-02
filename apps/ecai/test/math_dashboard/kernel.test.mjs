import assert from 'node:assert/strict';
import {test} from 'node:test';
import {
  realOvalPoint, imageContour, resampleContour,
  fourierCoefficients, fourierPoint, initMathKernel
} from '../../priv/static/js/ecai-math-kernel.js';

const TAU = 2 * Math.PI;

test('every sampled real source point satisfies y²=x³-4x (within floating-point tolerance)', () => {
  for (let j = 0; j < 600; j++) {
    const {x, y} = realOvalPoint(TAU * j / 600);
    assert.ok(x >= -2 - 1e-12 && x <= 1e-12);
    assert.ok(Math.abs(y * y - (x ** 3 - 4 * x)) < 1e-11);
  }
});

test('all shapes have finite contour geometry with bounded sample sizes', () => {
  for (const kind of ['oval','dragonfly','flower']) {
    const contour = imageContour(kind);
    assert.ok(contour.length > 50 && contour.length < 2000);
    assert.ok(contour.every(p => Number.isFinite(p.x) && Number.isFinite(p.y)));
    const samples = resampleContour(contour, 800);
    assert.equal(samples.length, 800);
    assert.ok(samples.every(p => Number.isFinite(p.x) && Number.isFinite(p.y)));
  }
  assert.throws(() => imageContour('evil'));
});

test('adding Fourier harmonics reduces reconstruction error on each sample', () => {
  for (const kind of ['oval','dragonfly','flower']) {
    const samples = resampleContour(imageContour(kind), 800);
    const coefficients = fourierCoefficients(samples, 80);
    assert.equal(coefficients.size, 161);
    const error = order => Math.sqrt(samples.reduce((sum, point, j) => {
      const reconstructed = fourierPoint(coefficients, j / samples.length, order);
      return sum + (point.x - reconstructed.x) ** 2 + (point.y - reconstructed.y) ** 2;
    }, 0) / samples.length);
    assert.ok(error(12) < error(1), `${kind}: order 12 should beat order 1`);
    assert.ok(error(80) < error(12), `${kind}: order 80 should beat order 12`);
    assert.ok(error(80) < .01, `${kind}: high-order reconstruction ${error(80)}`);
  }
});

test('complex Fourier series is periodic and its zero mode is the sample mean', () => {
  const points = resampleContour(imageContour('flower'), 800);
  const coeffs = fourierCoefficients(points, 80);
  let x = 0, y = 0;
  for (const p of points) { x += p.x; y += p.y; }
  assert.ok(Math.abs(coeffs.get(0).re - x / points.length) < 1e-11);
  assert.ok(Math.abs(coeffs.get(0).im - y / points.length) < 1e-11);
  for (let t = 0; t <= 1; t += .125) {
    const a = fourierPoint(coeffs, t, 12), b = fourierPoint(coeffs, t + 1, 12);
    assert.ok(Math.hypot(a.x - b.x, a.y - b.y) < 1e-11);
  }
});

test('native dashboard controller is a no-op without a DOM', () => {
  const controller = initMathKernel();
  controller.setVisible(true);
  controller.dispose();
});
