"""Source-level regression contracts. Not a substitute for Erlang/EUnit tests."""
from pathlib import Path
import unittest

APP = Path(__file__).resolve().parents[1]


class InferenceStatusRecoveryContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.store = (APP / 'src/ecai_learning_store.erl').read_text()
        cls.snapshot = (APP / 'src/ecai_learning_snapshot.erl').read_text()
        cls.pool = (APP / 'src/ecai_ollama_pool.erl').read_text()
        cls.settings = (APP / 'src/ecai_llm_settings.erl').read_text()
        cls.ui = (APP / 'priv/static/js/ecai-llm-settings.js').read_text()
        cls.shell = (APP / 'priv/static/js/ecai-console.js').read_text()
        cls.diagnostics = (APP / 'src/ecai_inference_diagnostics.erl').read_text()

    def test_collection_handlers_defer_work(self):
        callbacks = self.store.split('handle_call(stop,', 1)[1].split('handle_cast(', 1)[0]
        self.assertNotIn('dets:foldl', callbacks)
        for query in ['repairs = Q', 'snapshot_data = Q', '{events, _, _, _} = Q']:
            self.assertIn(query, callbacks)
        self.assertIn('enqueue_query(Q, From, State)', callbacks)
        self.assertIn('-define(QUERY_WORKERS, 2)', self.store)
        self.assertIn('-define(MAX_QUERIES, 32)', self.store)
        self.assertIn('caller_monitor => erlang:monitor(process, Caller)', self.store)
        self.assertIn('{query_timeout, Ref}', self.store)
        self.assertIn('gen_server:reply(maps:get(from, Q), Reply)', self.store)

    def test_key_only_index_and_incremental_reads(self):
        self.assertIn("dets:select(Tab, [{{'$1', '_'}, [], ['$1']}], 256)", self.store)
        self.assertIn('ets:insert(Index, {{Bucket, Key}})', self.store)
        self.assertIn('query_result(Request, {indexed, Tab, Keys})', self.store)
        self.assertIn('fold_records(Fun, Acc, {indexed, Tab, Keys})', self.store)
        buckets = self.store.split('index_buckets({analysis,', 1)[1].split('query_bucket(', 1)[0]
        self.assertNotIn('relations,', buckets)

    def test_snapshot_is_fenced_not_silently_inconsistent(self):
        self.assertIn('write_revision = 0', self.store)
        self.assertIn('Revision =/= State#state.write_revision', self.store)
        self.assertIn('{error, learning_store_snapshot_busy}', self.store)
        self.assertIn('snapshot_data() -> snapshot_data(2)', self.store)
        self.assertIn('error({learning_snapshot_unavailable, Why})', self.snapshot)
        self.assertIn('catch error:{learning_snapshot_unavailable, Why} -> {error, Why}', self.snapshot)

    def test_status_does_not_traverse_receipts(self):
        status = self.pool.split('receipt_status(State) ->', 1)[1].split('public_receipt(', 1)[0]
        self.assertNotIn('dets:', status)
        self.assertIn('statuses => State#state.receipt_counts', status)
        self.assertIn('receipt_counts = load_receipt_counts(ReceiptTab)', self.pool)
        self.assertIn('Before = receipt_key_status(Tab, Key)', self.pool)
        self.assertIn('After = receipt_key_status(Tab, Key)', self.pool)

    def test_probes_are_deduplicated_and_capacity_is_distinct(self):
        self.assertIn('{ok, #{token := Token}} -> State', self.pool)
        self.assertIn('probe_verified, Node, false', self.pool)
        self.assertIn('available_capacity =>', self.pool)
        self.assertIn('oldest_inflight_ms =>', self.pool)
        self.assertIn('last_request_error => ecai_inference_diagnostics:public_error(Error)', self.pool)
        self.assertIn('probe_latency_ms => DurationMs', self.pool)

    def test_diagnostics_do_not_serialize_arbitrary_provider_errors(self):
        self.assertNotIn('io_lib:', self.diagnostics)
        self.assertNotIn('jsx:', self.diagnostics)
        self.assertIn('http_status => Status', self.diagnostics)
        self.assertIn('detail(response_body, Why)', self.diagnostics)
        self.assertIn('public_error(_) -> #{code => inference_error}', self.diagnostics)
        self.assertIn('transport_reason(_) -> request_failed', self.diagnostics)

    def test_saved_probe_budget_and_endpoint_policy(self):
        self.assertIn('Timeout = maps:get(health_timeout, Opts)', self.settings)
        self.assertIn('{probe_current, maps:get(revision, Target)}', self.settings)
        self.assertIn('default_model_available => maps:is_key(Default, Models)', self.settings)
        self.assertIn('proxy => maps:get(proxy, Preserved, direct)', self.settings)
        self.assertIn('max_response_bytes => response_limit(Preserved)', self.settings)
        self.assertIn('deployment_connections => Connections', self.settings)
        self.assertIn('#{managed := true, nodes := Ns} -> {ok, Ns}', self.settings)

    def test_ui_live_status_does_not_overwrite_secrets_or_enable_nodes(self):
        self.assertIn('void llmSettings?.poll()', self.shell)
        poll = self.ui.split('async function poll()', 1)[1].split('async function save(', 1)[0]
        self.assertIn('document.hidden', poll)
        self.assertIn('if (!dirty && revision !== next.revision) fillDraft()', poll)
        self.assertNotIn('clearKeys()', poll)
        self.assertIn('data.pool = {available: false}', poll)
        self.assertIn('structuredClone(c), enabled: false', self.ui)
        self.assertIn('SATURATED (healthy does not mean idle)', self.ui)
        self.assertIn('current()?.id !== id', self.ui)


if __name__ == '__main__':
    unittest.main()
