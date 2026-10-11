import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
const source = await readFile(new URL('../../priv/static/js/dashboard-tax-reports.js', import.meta.url), 'utf8');
const {normalizeTaxReport, normalizeTaxReports, filterTaxReports, reportStatus,
  latestYearSummary, reportIndexCsv, reportIndexRecords, audCents, formatMinor,
  validateRegionProfile, taxYearForDate, buildBackfillPayload, initDashboardTaxReports} =
  await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`);
const hash = digit => digit.repeat(64);
const report = (year, stamp, review, digest, ready = false, events = 2) => ({
  tax_year_end: year, generated_at: stamp, review_count: review,
  manifest_sha256: digest, evidence_set_sha256: hash('e'), attestable: ready,
  summary: {total_events: events, ordinary_income_cents: 10234, expense_candidates_cents: 201,
    cgt_raw_gains_cents: 0, cgt_raw_losses_cents: 0}
});
const fixture = [
  report(2026, 100, 2, hash('a')),
  report(2026, 200, 0, hash('b'), true, 3),
  report(2025, 150, 3, hash('c'), false, 4),
  report(2024, 90, 0, hash('d'), false, 1)
];

test('rejects invalid hashes, years and metadata, deduplicates report revisions', () => {
  for (const wrong of [null, {}, {tax_year_end: 2026, manifest_sha256: '../../escape'},
    {...fixture[0], tax_year_end: 3000}, {...fixture[0], manifest_sha256: '=evil'.padEnd(64, 'a')}]) {
    assert.equal(normalizeTaxReport(wrong), null);
  }
  assert.equal(normalizeTaxReports([...fixture, fixture[0], {bad: true}]).length, 4);
});

test('latest revision per year is selected before search and status filters', () => {
  assert.equal(filterTaxReports(fixture).length, 3);
  assert.equal(filterTaxReports(fixture, {year: '2026'})[0].manifest_sha256, hash('b'));
  assert.equal(filterTaxReports(fixture, {status: 'ready'}).length, 1);
  assert.equal(filterTaxReports(fixture, {status: 'review', revisions: 'all'}).length, 3);
  assert.equal(filterTaxReports(fixture, {search: hash('a')}).length, 0); // old revision hidden
  assert.equal(filterTaxReports(fixture, {search: hash('a'), revisions: 'all'}).length, 1);
  assert.equal(filterTaxReports(fixture, {year: '2020'}).length, 0);
});

test('status is review required unless attestable and zero review items', () => {
  assert.equal(reportStatus(normalizeTaxReport(fixture[1])), 'ready');
  assert.equal(reportStatus(normalizeTaxReport(fixture[3])), 'review');
});

test('summary counts latest FY revisions once, not all historical copies', () => {
  assert.deepEqual(latestYearSummary(fixture), {years: 3, events: 8, review: 3});
});

test('filtered CSV/JSON indexes contain allowlisted fields with AUD cents precision', () => {
  const rows = filterTaxReports(fixture, {year: '2026'});
  const csv = reportIndexCsv(rows);
  const json = reportIndexRecords(rows);
  assert.equal(json.length, 1);
  assert.equal(json[0].ordinary_income_aud, '102.34');
  assert.equal(json[0].expense_candidates_aud, '2.01');
  assert.equal(json[0].manifest_sha256, hash('b'));
  assert.equal(json[0].status, 'ready');
  assert.equal(json[0].payment_preimage, undefined);
  assert.ok(csv.includes('"ordinary_income_aud"'));
  assert.ok(csv.includes('"102.34"'));
  assert.ok(!csv.includes('payment_preimage'));
  assert.equal(audCents(-252), '-2.52');
  const negative = normalizeTaxReport({...fixture[0], summary: {...fixture[0].summary, ordinary_income_cents: -252}});
  assert.ok(reportIndexCsv([negative]).includes('"-2.52"'));
  assert.equal(audCents(Number.NaN), '');
});

test('no DOM / no browser side effects when importing helpers in Node', () => {
  assert.equal(initDashboardTaxReports(), null);
});

test('a country and year identify an independent latest revision', () => {
  const us = {...fixture[1], manifest_sha256: hash('f'), jurisdiction: 'US', currency: 'USD', summary: {
    total_events: 2, ordinary_income_minor: 1234, expense_candidates_minor: 55,
    cgt_raw_gains_minor: 0, cgt_raw_losses_minor: 0}};
  const withRegions = [...fixture, us];
  assert.equal(filterTaxReports(withRegions, {year: '2026'}).length, 2);
  assert.equal(filterTaxReports(withRegions, {jurisdiction: 'US'}).length, 1);
  assert.equal(latestYearSummary(withRegions).years, 4);
  const [row] = reportIndexRecords(filterTaxReports(withRegions, {jurisdiction: 'US'}));
  assert.equal(row.ordinary_income_fiat, '12.34');
  assert.equal(row.ordinary_income_aud, '');
  assert.equal(row.fiat_currency, 'USD');
  assert.ok(reportIndexCsv([normalizeTaxReport(us)]).includes('"USD"'));
  assert.ok(!reportIndexCsv([normalizeTaxReport(us)]).includes('"ordinary_income_usd"'));
});

test('JPY exports have zero minor decimal digits and no AUD alias', () => {
  const jp = normalizeTaxReport({...fixture[0], jurisdiction: 'JP', currency: 'JPY',
    minor_digits: 0, summary: {total_events: 1, ordinary_income_minor: 15001,
      expense_candidates_minor: 0, cgt_raw_gains_minor: 0, cgt_raw_losses_minor: 0}});
  const [row] = reportIndexRecords([jp]);
  assert.equal(row.ordinary_income_fiat, '15001');
  assert.equal(row.ordinary_income_aud, '');
  assert.equal(formatMinor(-15, 0), '-15');
});

test('country period selection and boundary math obey UK April 6 and AU July 1', () => {
  const gb = {code: 'GB', name: 'United Kingdom', currency: 'GBP',
    start_month: 4, start_day: 6, default_offset_minutes: 0};
  const au = {...gb, code: 'AU', currency: 'AUD', start_month: 7, start_day: 1,
    default_offset_minutes: 600};
  assert.equal(validateRegionProfile(gb), true);
  assert.equal(taxYearForDate(gb, new Date('2026-04-05T12:00:00Z')), 2026);
  assert.equal(taxYearForDate(gb, new Date('2026-04-06T12:00:00Z')), 2027);
  assert.equal(taxYearForDate(au, new Date('2026-06-30T13:59:59Z')), 2026);
  assert.equal(taxYearForDate(au, new Date('2026-06-30T14:00:00Z')), 2027);
  assert.deepEqual(buildBackfillPayload('GB', 0, 4, '2027', true),
    {year: 2027, source: 'journal', jurisdiction: 'GB',
     standard_utc_offset_minutes: 0, period_start_month: 4});
  assert.throws(() => buildBackfillPayload('../../etc', 0, 4, 'all', false));
  assert.throws(() => buildBackfillPayload('US', -900, 1, 'all', false));
});
