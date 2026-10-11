#!/usr/bin/env python3
"""Chromium smoke tests for the embedded tax-report admin view (mocked private API)."""
import json
import shutil
import unittest
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).parent))
from bdd_composer_browser_test import render_template

TEMPLATE = ROOT / 'priv/templates/ui/dashboard/node_tax_reports_tab.mustache'
SCRIPT = ROOT / 'priv/static/js/dashboard-tax-reports.js'


def report(year, stamp, char, review, attestable, count):
    return {'tax_year_end': year, 'generated_at': stamp, 'manifest_sha256': char * 64,
            'evidence_set_sha256': 'e' * 64, 'review_count': review, 'attestable': attestable,
            'summary': {'total_events': count, 'ordinary_income_cents': 12500,
                        'expense_candidates_cents': 100, 'cgt_raw_gains_cents': 0,
                        'cgt_raw_losses_cents': 0}}


REPORTS = [report(2027, 1780000000, 'a', 5, False, 9),
           report(2027, 1781000000, 'b', 0, True, 11),
           report(2026, 1740000000, 'c', 2, False, 4),
           {'tax_year_end': 2028, 'manifest_sha256': '<script>alert(1)</script>'}]


class TaxDashboardBrowserTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        try:
            from playwright.sync_api import sync_playwright
        except ImportError:
            raise unittest.SkipTest('Playwright is unavailable')
        chromium = shutil.which('chromium') or shutil.which('chromium-browser')
        if not chromium:
            raise unittest.SkipTest('Chromium is unavailable')
        cls.pw = sync_playwright().start()
        cls.browser = cls.pw.chromium.launch(headless=True, executable_path=chromium,
                                             args=['--no-sandbox'])

    @classmethod
    def tearDownClass(cls):
        if hasattr(cls, 'browser'):
            cls.browser.close()
            cls.pw.stop()

    def setUp(self):
        self.page = self.browser.new_page(accept_downloads=True)
        self.page.set_default_timeout(5000)
        self.addCleanup(self.page.close)
        fragment = render_template(TEMPLATE.read_text(), {'tax_enabled': True})
        self.page.set_content('<div id="node-tax-reports-tab">' + fragment + '</div>')
        self.page.evaluate('''(reports) => {
            window.__taxCalls = [];
            window.__taxReports = reports;
            window.__taxJob = {status: 'idle'};
            window.fetch = async (url, options = {}) => {
                window.__taxCalls.push({url: String(url), options});
                const path = String(url);
                const data = path.endsWith('/reports') ? {reports: window.__taxReports} :
                    path.endsWith('/jurisdictions') ? {
                        default_jurisdiction: 'AU', jurisdictions: [
                          {code: 'AU', name: 'Australia', currency: 'AUD',
                           start_month: 7, start_day: 1, default_offset_minutes: 600,
                           custom_period: false},
                          {code: 'US', name: 'United States', currency: 'USD',
                           start_month: 1, start_day: 1, default_offset_minutes: 0,
                           custom_period: true}
                        ]} :
                    path.endsWith('/jobs') ? {job: window.__taxJob} :
                    path.endsWith('/backfill') ? {status: 'started'} : {error: 'unknown'};
                if (path.endsWith('/backfill')) window.__taxJob = {status: 'running'};
                return new Response(JSON.stringify(data), {status: 200, headers: {'content-type': 'application/json'}});
            };
        }''', REPORTS)
        self.page.add_script_tag(content=SCRIPT.read_text(), type='module')
        self.page.locator('#tax-years-count').filter(has_text='2').wait_for()
        self.page.locator('#tax-backfill-jurisdiction option[value="AU"]').wait_for(state='attached')

    def test_filters_and_review_status(self):
        self.assertIn('2 matching reports', self.page.locator('#tax-reports-count').inner_text())
        self.page.locator('#tax-filter-status').select_option('ready')
        self.assertIn('1 matching report', self.page.locator('#tax-reports-count').inner_text())
        self.page.locator('#tax-filter-status').select_option('all')
        self.page.locator('#tax-filter-revisions').select_option('all')
        self.assertIn('3 matching reports', self.page.locator('#tax-reports-count').inner_text())
        self.page.locator('#tax-filter-search').fill('a' * 64)
        self.assertIn('1 matching report', self.page.locator('#tax-reports-count').inner_text())
        self.assertNotIn('<script>', self.page.locator('#tax-reports-rows').inner_html())

    def test_filtered_index_export_is_metadata_only(self):
        self.page.locator('#tax-filter-year').select_option('2027')
        with self.page.expect_download() as evt:
            self.page.locator('#tax-export-csv').click()
        download = evt.value
        self.assertEqual('damagebdd-tax-report-index.csv', download.suggested_filename)
        csv = Path(download.path()).read_text(encoding='utf-8-sig')
        self.assertIn('"' + 'b' * 64 + '"', csv)
        self.assertNotIn('"' + 'a' * 64 + '"', csv)
        self.assertNotIn('preimage', csv)
        self.assertIn('"125.00"', csv)
        with self.page.expect_download() as evt:
            self.page.locator('#tax-export-json').click()
        records = json.loads(Path(evt.value.path()).read_text())['reports']
        self.assertEqual(1, len(records))
        self.assertEqual('b' * 64, records[0]['manifest_sha256'])
        self.assertEqual('ready', records[0]['status'])

    def test_pagination_keeps_full_filtered_index_export(self):
        many = [report(2027, 1780000000 + n, 'a', n % 3, False, n + 1)
                for n in range(1, 30)]
        # Use distinct SHA-256-shaped digests rather than repeating hex characters.
        for n, item in enumerate(many, 1):
            item['manifest_sha256'] = f'{n:064x}'
        self.page.evaluate('(reports) => { window.__taxReports = reports; }', many)
        self.page.locator('#tax-reports-refresh').click()
        self.page.locator('#tax-reports-count').filter(has_text='29 revisions').wait_for()
        self.page.locator('#tax-filter-revisions').select_option('all')
        self.assertEqual(20, self.page.locator('#tax-reports-rows tr').count())
        self.assertEqual('Page 1 of 2', self.page.locator('#tax-page-label').inner_text())
        self.page.locator('#tax-next-page').click()
        self.assertEqual(9, self.page.locator('#tax-reports-rows tr').count())
        self.assertEqual('Page 2 of 2', self.page.locator('#tax-page-label').inner_text())
        with self.page.expect_download() as evt:
            self.page.locator('#tax-export-json').click()
        records = json.loads(Path(evt.value.path()).read_text())['reports']
        self.assertEqual(29, len(records))

    def test_report_country_filter_and_fiat_currency(self):
        self.page.locator('#tax-backfill-jurisdiction').select_option('US')
        self.assertEqual('0', self.page.locator('#tax-backfill-offset').input_value())
        self.assertFalse(self.page.locator('#tax-backfill-month').is_disabled())

    def test_backfill_uses_admin_header_and_journal_scope(self):
        self.page.locator('#tax-backfill-year').select_option('2027')
        self.page.locator('#tax-backfill-journal').check()
        self.page.locator('#tax-backfill-run').click()
        self.page.wait_for_function("window.__taxCalls.some(x => x.url.endsWith('/backfill'))")
        call = self.page.evaluate("window.__taxCalls.find(x => x.url.endsWith('/backfill'))")
        self.assertEqual({'year': 2027, 'source': 'journal', 'jurisdiction': 'AU',
                          'standard_utc_offset_minutes': 600, 'period_start_month': 7},
                         json.loads(call['options']['body']))
        self.assertEqual('1', call['options']['headers']['X-Damage-Tax-Request'])
        self.assertEqual('same-origin', call['options'].get('credentials'))


if __name__ == '__main__':
    unittest.main()
