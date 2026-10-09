"""Static route/markup regression contract for the ECAI control plane.

Runs with Python's standard library only; actual Cowboy/Erlang integration
is exercised by the umbrella's regular rebar3 suite.
"""
import re
import unittest
from html.parser import HTMLParser
from pathlib import Path

APP = Path(__file__).resolve().parents[1]
JS = APP / 'priv/static/js/ecai-console.js'
HTML = APP / 'priv/templates/ui/dashboard/ecai_console.mustache'
CSS = APP / 'priv/static/css/ecai-console.css'

class Elements(HTMLParser):
    def __init__(self):
        super().__init__()
        self.ids = []
        self.views = []
        self.panels = []
        self.scripts = []
        self.styles = []
    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if 'id' in attrs:
            self.ids.append(attrs['id'])
        if 'data-view' in attrs:
            self.views.append(attrs['data-view'])
        if 'data-panel' in attrs:
            self.panels.append(attrs['data-panel'])
        if tag == 'script' and attrs.get('src'):
            self.scripts.append(attrs['src'])
        if tag == 'link' and attrs.get('rel') == 'stylesheet':
            self.styles.append(attrs.get('href'))

class ConsoleContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.js = JS.read_text(encoding='utf-8')
        cls.html = HTML.read_text(encoding='utf-8')
        cls.markup = Elements()
        cls.markup.feed(cls.html)

    def test_static_assets_resolve(self):
        self.assertTrue(JS.is_file())
        self.assertTrue(CSS.is_file())
        for asset in self.markup.scripts + self.markup.styles:
            self.assertTrue((APP / 'priv/static' / asset.removeprefix('/static/')).is_file(), asset)

    def test_dom_ids_are_unique_and_used(self):
        self.assertEqual(len(self.markup.ids), len(set(self.markup.ids)))
        refs = set(re.findall(r'\$\([\"\']([^\"\']+)[\"\']\)', self.js))
        self.assertFalse(refs.difference(self.markup.ids), refs.difference(self.markup.ids))

    def test_ten_views_have_navigation(self):
        views = {'overview','search','chat','indexing','wikimedia',
                 'knowledge','marketplace','operations','code','api','network'}
        self.assertEqual(set(self.markup.views), views)
        self.assertEqual(set(self.markup.panels), views)

    def test_api_catalog_matches_cowboy_routes(self):
        catalog = set(re.findall(r'method:\s*"(GET|POST|SSE|WS)",\s*path:\s*"([^"]+)"', self.js))
        self.assertEqual(len(catalog), 66)
        declared = {
            ('GET','/ecai/auth/session'),
            ('POST','/ecai/search'), ('GET','/ecai/chat'), ('POST','/ecai/chat'),
            ('POST','/v1/chat/completions'), ('POST','/ecai/ekef'),
            ('WS','/ecai/ws/'),
        }
        declared |= {('POST',f'/ecai/private/:corpus/{action}') for action in ('index','search','fetch','ask')}
        declared |= {('GET',f'/ecai/wikimedia/{action}') for action in ('sources','plan','search','doctor')}
        declared |= {('GET',f'/ecai/index-jobs/{suffix}') for suffix in ('status','presets',':id',':id/artifact')}
        declared |= {('GET','/ecai/index-jobs'),('POST','/ecai/index-jobs'),
                     ('POST','/ecai/index-jobs/presets/:preset'),('SSE','/ecai/index-jobs/:id/events')}
        declared |= {('POST',f'/ecai/index-jobs/:id/{action}') for action in ('pause','resume','cancel','retry')}
        declared |= {('GET',f'/ecai/market/jobs{suffix}') for suffix in ('', '/:id')}
        declared |= {('POST',f'/ecai/market/jobs{suffix}') for suffix in ('/publish','/:id/claim','/:id/submit','/:id/pay')}
        declared |= {('GET',f'/yelp/{action}') for action in ('status','chunk_job')}
        declared |= {('POST',f'/yelp/{action}') for action in ('chunk','chunk_async','chunk_cancel','assign','ipfs','headers','manifest')}
        declared |= {('GET',f'/ecai/admin/code/{action}') for action in ('status','repairs','reviews')}
        declared |= {('POST',f'/ecai/admin/code/{action}') for action in ('learn','scan','propose','integrate')}
        declared.add(('GET','/ecai/admin/code/reviews/:id'))
        declared |= {('POST',f'/ecai/admin/code/reviews/:id/{action}') for action in ('approve','reject','publish')}
        declared |= {('GET', '/ecai/admin/index-pool' + p) for p in ('/status', '/jobs/:id/contract')}
        declared |= {('POST', '/ecai/admin/index-pool' + p) for p in ('/nodes','/prepare','/channels','/quote','/jobs','/jobs/:id/start','/jobs/:id/pause','/jobs/:id/reconcile','/jobs/:id/refund','/jobs/:id/refund-pay','/jobs/:id/search')}
        self.assertEqual(catalog, declared)

    def test_canceled_retry_requeues_durable_checkpoint(self):
        srv = (APP / 'src/ecai_index_jobs_srv.erl').read_text(encoding='utf-8')
        sse = (APP / 'src/ecai_index_jobs_sse.erl').read_text(encoding='utf-8')
        self.assertIn('state := canceled} = Job0', srv)
        self.assertIn('requeue_checkpoint(Job0, operator_resume_canceled, State0)', srv)
        self.assertIn('resumed_from_checkpoint =>', srv)
        self.assertIn('case ensure_queue_capacity(Owner, State0)', srv)
        self.assertIn('case current_job_is_terminal(JobId) of', sse)
        self.assertIn('replay_pages(JobId, LastSeq, Req)', sse)
        self.assertIn('session.controller?.abort()', self.js)
        self.assertIn('Resume from checkpoint', self.js)

    def test_index_jobs_render_collapsible_cards_and_stream_on_open(self):
        self.assertIn('id="indexJobList"', self.html)
        self.assertNotIn('id="indexRows"', self.html)
        self.assertNotIn('id="indexJobPanel"', self.html)
        self.assertIn('createJobEntry(job)', self.js)
        self.assertIn('item.addEventListener("toggle", () => onJobToggle(entry))', self.js)
        self.assertIn('startJobStream(entry)', self.js)
        self.assertIn('if (!entry.item.open)', self.js)
        self.assertIn('stopStream();', self.js)
        self.assertIn('other.item.open = false', self.js)

    def test_job_polling_reuses_entries_and_preserves_event_sequences(self):
        self.assertIn('state.jobEntries = next;', self.js)
        self.assertIn('const entry = previous.get(id) || createJobEntry(job)', self.js)
        self.assertIn('parent.insertBefore(entry.item, parent.children[pos] || null)', self.js)
        self.assertIn('oldSeq > newSeq', self.js)
        self.assertIn('seq >= (Number(entry.job.event_seq) || 0)', self.js)
        self.assertIn('after_seq=', self.js)
        self.assertIn('session.controller?.abort()', self.js)
        server = (APP / 'src/ecai_index_jobs_sse.erl').read_text(encoding='utf-8')
        self.assertIn('after_seq', server)
        self.assertIn('current_job_is_terminal', server)

    def test_index_job_cards_are_responsive_and_accessible(self):
        css = CSS.read_text(encoding='utf-8')
        self.assertIn('index-job-summary:focus-visible', css)
        self.assertIn('prefers-reduced-motion: reduce', css)
        self.assertIn('grid-template-columns: repeat(auto-fit', css)
        self.assertIn('aria-label', self.js)
        self.assertIn('renderJobDetails(entry)', self.js)

    def test_wikimedia_picker_uses_server_catalog_and_durable_queue(self):
        required = {'wikiPresetChoices', 'wikiPresetSearch', 'wikiSelectedCount',
                    'wikiQueueSelected', 'wikiEnqueueResults', 'wikiProject',
                    'wikiPageviewProject', 'wikiRelease', 'wikiMonthChoices',
                    'wikiPlanSummary', 'wikiPlanLimit', 'wikiPlanBtn',
                    'wikiQueuePlanBtn'}
        self.assertTrue(required.issubset(self.markup.ids), required - set(self.markup.ids))
        for call in ('refreshWikiProjects()', 'queueSelectedWikiPresets()',
                     'discoverWikiSources()', 'previewWikiPlan()', 'queueWikiPlan()'):
            self.assertIn(call, self.js)
        self.assertIn('"/ecai/index-jobs/presets"', self.js)
        self.assertIn('`/ecai/index-jobs/presets/${encodeURIComponent(preset.id)}`', self.js)
        self.assertIn('`/ecai/wikimedia/plan${queryString(params)}`', self.js)
        self.assertIn('method: "POST", body: plan.spec', self.js)
        self.assertIn('"Idempotency-Key": plan.key', self.js)
        self.assertIn('plan.inputKey !== wikiInputIdentity()', self.js)
        self.assertIn('state.wikiPresetKeys.set(String(preset.id), key)', self.js)
        self.assertIn('state.wikiMonthsSelected.size', self.js)
        self.assertNotIn('wikiRequest("sources", wikiParams()', self.js)
        ops = (APP / 'src/ecai_wikimedia_ops.erl').read_text()
        self.assertIn('default_project_dir(Project)', ops)
        self.assertIn('valid_project_token(Project)', ops)

    def test_root_console_and_legacy_routes(self):
        source = (APP/'src/ecai_dashboard.erl').read_text(encoding='utf-8')
        for route in ('/','/dashboard','/search','/chat','/indexer','/indexer/advanced'):
            self.assertIn('"'+route+'"', source)
        self.assertIn('"ecai_console.mustache"', source)

    def test_code_review_backend_is_fail_closed(self):
        app = (APP/'src/ecai_app.erl').read_text(encoding='utf-8')
        sup = (APP/'src/ecai_code_security_sup.erl').read_text(encoding='utf-8')
        config = (APP/'src/ecai.app.src').read_text(encoding='utf-8')
        http = (APP/'src/ecai_code_admin_http.erl').read_text(encoding='utf-8')
        queue = (APP/'src/ecai_code_review_queue.erl').read_text(encoding='utf-8')
        git = (APP/'src/ecai_code_review_git.erl').read_text(encoding='utf-8')
        self.assertIn('code_admin_handlers()', app)
        self.assertIn('review_queue_specs()', sup)
        self.assertIn('{code_admin_enabled, false}', config)
        self.assertIn('{code_review_push_enabled, false}', config)
        self.assertIn('{code_admin_accounts, []}', config)
        self.assertIn('damage_http:is_authorized', http)
        self.assertIn('damage_auth:authenticated_account(State)', http)
        self.assertIn('bearer_required', http)
        self.assertIn('Action =:= propose;', http)  # POST must be actually routable
        self.assertIn('repair_blocked', http)
        self.assertIn('ecai_node_admin:can_manage_code(Account)', http)
        policy = (APP / 'src/ecai_node_admin.erl').read_text(encoding='utf-8')
        self.assertIn('application:get_env(damage, node_admins, [])', policy)
        self.assertIn('allowed_by_policy', policy)
        self.assertIn('repair_superseded', queue)
        self.assertIn('duplicate_reviewer', queue)
        self.assertIn('Base/binary, 0, Sha/binary', queue)
        self.assertIn('verification => compact_verification(Verified)', queue)
        self.assertIn('reconcile_required', queue)
        self.assertIn('publisher_is_reviewer', queue)
        self.assertIn('patch_hash_mismatch', queue)
        self.assertIn('stale_review_revision', queue)
        self.assertIn('publication_gate(R, Actor)', queue)
        self.assertIn('ecai_code_review_queue:get(cowboy_req:binding(id, Req), Actor)', http)
        self.assertIn('current_repair', queue)
        self.assertIn('ecai_patch_verifier:verify_patchset', git)
        self.assertIn('stale_base_commit', git)
        self.assertIn('push_committed_review', git)
        self.assertIn('"worktree", "add", "--detach"', git)
        self.assertIn('"--no-verify", "origin"', git)
        self.assertNotIn('"--force", "origin"', git)
        self.assertIn('ecai/reviews/', git)

    def test_admin_repairs_filter_validated_and_link_to_review_diff(self):
        for dom_id in ('codeRepairSearch', 'codeRepairValidation', 'codeRepairApp',
                       'codeRepairWithDiff', 'codeRepairRows', 'codeReviewRows',
                       'codeReviewSearch', 'codeReviewStatus', 'codeReviewApp',
                       'codeReviewValidation', 'codeReviewWorkspace'):
            self.assertIn(f'id="{dom_id}"', self.html)
        self.assertIn('reviewForRepair(repair)', self.js)
        self.assertIn('review.patch_sha256 === repair.patch_sha256', self.js)
        self.assertIn('review.base_commit === repair.base_commit', self.js)
        self.assertIn('openCodeReviewFromRepair(matching.id)', self.js)
        self.assertIn('reviewIsValidated(review)', self.js)
        self.assertIn('renderCodeRepairs(); renderCodeReviews()', self.js)

    def test_admin_reviews_expand_lazily_with_file_level_diffs(self):
        self.assertIn('card.addEventListener("toggle"', self.js)
        self.assertIn('if (card.open) void openCodeReviewCard(card, review)', self.js)
        self.assertIn('card.querySelector(".code-review-content").append(workspace)', self.js)
        self.assertIn('state.codeReviewLoadSerial', self.js)
        self.assertIn('splitCodePatch(patch)', self.js)
        self.assertIn('renderCodeDiff()', self.js)
        self.assertIn('id="codeDiffFileList"', self.html)
        self.assertIn('id="codeReviewDiff"', self.html)
        self.assertIn('code-diff-line.is-addition', CSS.read_text(encoding='utf-8'))
        self.assertIn('prefers-reduced-motion:reduce', CSS.read_text(encoding='utf-8'))
        self.assertNotIn('id="codeReviewRows"><tr', self.html)

    def test_code_mutations_continue_to_require_bearer(self):
        http = (APP/'src/ecai_code_admin_http.erl').read_text(encoding='utf-8')
        self.assertIn('<<"Bearer ", Token/binary>>', http)
        self.assertIn('bearer_required', http)
        self.assertIn('const bearer = typeof token === "string"', self.js)
        self.assertIn('$("codeApprove").disabled = !valid || !bearer', self.js)
        self.assertIn('$("codePublish").disabled = !valid || !publishEligible', self.js)
        self.assertIn('if (!hasBearer) reasons.unshift("bearer_required")', self.js)
        self.assertIn('id="codeBearerNotice"', self.html)

    def test_code_metrics_render_from_existing_server_status(self):
        for dom_id in ('codeMetrics', 'codeServiceCards', 'codeStatusUpdated',
                       'codePublishGate', 'codeLearningStatus', 'codeRepairStatus'):
            self.assertIn(f'id="{dom_id}"', self.html)
        for field in ('learner.progress_percent', 'patchManager.active',
                      'patchManager.pending', 'integration.job_counts',
                      'queue.required_approvals'):
            self.assertIn(field, self.js)
        self.assertIn('renderCodeOperations(learning, state.codeQueue)', self.js)
        self.assertIn('refreshCodeStatusOnly()', self.js)
        self.assertIn('server_gate_unavailable', self.js)
        self.assertIn('publisher_is_reviewer', self.js)

    def test_marketplace_opt_in_and_supervision(self):
        app = (APP/'src/ecai_app.erl').read_text(encoding='utf-8')
        sup = (APP/'src/ecai_sup.erl').read_text(encoding='utf-8')
        self.assertIn('marketplace_handlers()', app)
        self.assertIn('true -> [ecai_jobs_http]', app)
        self.assertIn('marketplace_specs()', sup)
        self.assertIn('{ecai_jobs_srv, start_link, []}', sup)
        self.assertIn('{marketplace_enabled, false}', (APP/'src/ecai.app.src').read_text(encoding='utf-8'))

class ConsoleAuthContractTests(unittest.TestCase):
    def test_account_routes_are_limited_to_login_logout(self):
        source = (APP/'src/ecai_app.erl').read_text(encoding='utf-8')
        self.assertIn('"/accounts/auth/", damage_accounts', source)
        self.assertIn('"/accounts/logout", damage_accounts', source)
        # Do not implicitly install the entire DamageBDD account router.
        self.assertNotIn('            damage_accounts,', source)
        for forbidden in ('/accounts/create', '/accounts/reset_password'):
            self.assertNotIn(forbidden, source)
        self.assertIn('] ++ code_admin_handlers() ++ marketplace_handlers()', source)

    def test_session_probe_is_present_and_non_billable(self):
        source = (APP/'src/ecai_auth_http.erl').read_text(encoding='utf-8')
        self.assertIn('damage_auth:authenticate(Req, State)', source)
        self.assertNotIn('damage_http:is_authorized(Req, State)', source)
        self.assertIn('<<"no-store">>', source)
        self.assertIn('"/ecai/auth/session"', source)
        app = (APP/'src/ecai_app.erl').read_text(encoding='utf-8')
        self.assertIn('            ecai_auth_http,', app)

    def test_node_admin_role_and_menu_are_consistent(self):
        auth = (APP/'src/ecai_auth_http.erl').read_text(encoding='utf-8')
        policy = (APP/'src/ecai_node_admin.erl').read_text(encoding='utf-8')
        http = (APP/'src/ecai_code_admin_http.erl').read_text(encoding='utf-8')
        js = JS.read_text(encoding='utf-8')
        self.assertIn('ecai_node_admin:is_node_admin(PublicKey)', auth)
        self.assertIn('code_admin_enabled => CodeEnabled', auth)
        self.assertIn('ecai_node_admin:can_manage_code(Account)', http)
        self.assertIn('application:get_env(damage, node_admins, [])', policy)
        self.assertIn('applyCodeSession(session)', js)
        self.assertIn('showCodeAdminNavigation()', js)
        self.assertIn('codeAdminDiagnostics(error)', js)

    def test_all_console_clients_probe_session_first(self):
        for filename in ('ecai-console.js', 'ecai-indexer.js', 'ecai-indexer-advanced.js'):
            source = (APP/'priv/static/js'/filename).read_text(encoding='utf-8')
            self.assertIn('"/ecai/auth/session"', source)
            self.assertIn('session?.authenticated' if 'indexer' in filename else 'session.authenticated', source)
        console = (APP/'priv/static/js/ecai-console.js').read_text(encoding='utf-8')
        self.assertLess(console.index('request("/ecai/auth/session"'),
                        console.index('request("/ecai/index-jobs/status"'))

if __name__ == '__main__':
    unittest.main(verbosity=2)
