"""Static source/configuration integration checks; NOT Erlang execution tests."""
import json
import re
import unittest
from pathlib import Path

APP = Path(__file__).resolve().parents[1]
def read(p): return (APP / p).read_text()

class SourceRetrievalContract(unittest.TestCase):
    def test_retention_is_distinct_from_excerpt(self):
        s=read('src/ecai_source_retrieval.erl')
        for x in ['retain/4','disk/2','disk_source/3','reassemble/3','original_utf8_bytes',
                  'source_hash_mismatch','source_length_mismatch','complete_source_not_retained',
                  'source_version_conflict']:
            self.assertIn(x, s + read('src/ecai_disk_docstore.erl'))
        self.assertIn('file:sync(Fd)',s)
        self.assertIn('ecai_chunker:validate_utf8',s)
        self.assertNotIn('damage_ipfs:',s)
    def test_original_bytes_are_retained_before_searchable_publication(self):
        s=read('src/ecai_ipfs_ingest.erl')
        self.assertIn('fetch_searchable(AbsoluteBaseDir, SourceKey, Cid, Title)',s)
        self.assertIn('ecai_source_retrieval:retain(BaseDir, Bytes, SourceKey, Cid)',s)
        self.assertIn('R#{source_blob => Ref}',s)
        self.assertIn('source_blob,',read('src/ecai_disk_indexer.erl'))
    def test_source_recovery_refuses_untrusted_paths_and_mixed_chunks(self):
        s=read('src/ecai_source_retrieval.erl')
        for x in ['byte_size(Sha) =:= 64','invalid_source_digest','mixed_source_versions',
                  'chunk_overlap_mismatch','chunk_ordinal_gap','incomplete_source']:
            self.assertIn(x,s)
        h=read('src/ecai_knowledge_http.erl')
        allowed=h.split('Allowed = ',1)[1].split(',',1)[0]
        self.assertNotIn('path',allowed)
        self.assertNotIn('binary_to_atom(',h)
        self.assertNotIn('list_to_atom(',h)
    def test_source_http_derives_owner_and_strict_bearer(self):
        h=read('src/ecai_knowledge_http.erl')
        for x in ['damage_auth:authenticated_account','damage_auth:resolve_oauth(Token,#{})',
                  'invalid_credentials','no-store','byte_size(Bytes) =< 16384','ValidSha','ValidOrd']:
            self.assertIn(x,h)
        self.assertNotIn('maps:get(<<"owner">>',h)
        self.assertNotIn('maps:get(<<"principal">>',h)
    def test_routes_are_registered(self):
        self.assertIn('ecai_knowledge_http,',read('src/ecai_app.erl'))
        h=read('src/ecai_knowledge_http.erl')
        for endpoint in ['search','source','status']:
            self.assertIn('/ecai/knowledge/'+endpoint,h)
    def test_live_queries_use_body_terms_without_release_proofs(self):
        s=read('src/ecai_wikimedia_search.erl')
        self.assertIn('text => Query,',s)
        self.assertIn('include_proofs',read('src/ecai_search.erl'))
        self.assertIn('include_proofs => false',read('src/ecai_knowledge.erl'))
        self.assertIn('Stored#{terms => All}',read('src/ecai_search.erl'))
    def test_dump_full_text_and_partial_opening_are_distinct(self):
        s=read('src/ecai_wikimedia_content.erl')
        for x in ['ecai-wikimedia-content/v2','<<"source_text">> => SourceText',
                  '<<"cirrus_excerpt">>, false','<<"cirrus_text_field">>, true']:
            self.assertIn(x,s)
        self.assertIn('ecai_source_retrieval:index_text',read('src/ecai_wikipedia_loader.erl'))
    def test_cache_generation_and_query_resource_cleanup(self):
        s=read('src/ecai_disk_search.erl')
        self.assertIn('filename:absname(BaseDir)',s)
        self.assertIn('crypto:hash(sha256, term_to_binary(Segs))',s)
        rag=read('src/ecai_ollama_rag.erl')
        self.assertIn('ecai_terms:terms_from_query(',rag)
        self.assertIn('after ets:delete(HotTab)',rag)
        self.assertIn('after ecai_disk_docstore:close(DocTab)',rag)
    def test_conversation_and_knowledge_share_registry(self):
        chat=read('src/ecai_chat.erl')
        self.assertIn('ecai_knowledge:context(',chat)
        self.assertNotIn('retrieve_sources("ecai_index"',chat)
        api=read('src/ecai_ollama_http.erl')
        self.assertIn('ecai_knowledge:context(undefined',api)
        self.assertIn('retrieve_public_context(Dir, Query, code)',api)
    def test_funded_preview_requires_acceptance_and_owner(self):
        r=read('src/ecai_index_pool_runner.erl')
        block=r.split('publish_live_manifest(J) ->',1)[1].split('\neligible(',1)[0]
        self.assertIn('=:= accepted',block)
        self.assertIn('ecai_index_shards:merge_plan',block)
        self.assertIn('live => true, final => false',block)
        pool=read('src/ecai_index_pool.erl')
        self.assertIn('maps:get(owner, J, undefined) =:= Owner',pool)
        self.assertIn('knowledge_manifests(_) -> []',pool)
    def test_blobs_travel_with_artifact_and_shard_sources_are_verified(self):
        self.assertIn('"sources", "*.bin"',read('src/ecai_index_artifact.erl'))
        s=read('src/ecai_index_shards.erl').split('source(ManifestPath, Ordinal, DocId)',1)[1]
        self.assertIn('verify_snapshot(',s)
        self.assertIn('ecai_search:source(Ctx, DocId)',s)
        self.assertIn('source_version_changed',read('src/ecai_knowledge.erl'))
    def test_cloud_and_mint_are_not_misrepresented_as_executed(self):
        s=read('src/ecai_compute_settings.erl')
        self.assertIn('<<"execution_integration">> => <<"pending">>',s)
        self.assertIn('<<"mint_submission_integration">> => <<"pending">>',s)
        for flag in ['index_rewards_enabled','index_pool_enabled']:
            self.assertIn('{'+flag+',false}',read('priv/config/source_retrieval.example.config'))
    def test_browser_reads_source_without_html_injection_or_identity_leak(self):
        s=read('priv/static/js/ecai-console.js')
        block=s.split('let knowledgeRefreshTimer',1)[1].split('function chatProject(',1)[0]
        for x in ['/ecai/knowledge/search','/ecai/knowledge/source','source_ref: result.source_ref',
                  'state.authEpoch !== searchAuthEpoch','ecai:identity-changed','replaceChildren()',
                  'searchLiveRefresh','panel.hidden','64000']:
            self.assertIn(x,block)
        self.assertNotIn('ignoreAuth: true',block)
        self.assertNotIn('.innerHTML',block)
    def test_profile_envelopes_match_runner_and_quote_schema(self):
        profiles=json.loads(read('priv/config/index_benchmark_profiles.json'))['profiles']
        runner=read('src/ecai_index_benchmark.erl')
        self.assertEqual(7,len(profiles))
        for p in profiles:
            self.assertIn('profile(<<"'+p['name']+'">>,'+str(p['logical_cpus'])+','+str(p['memory_gib'])+','+str(p['batch_docs']),runner)
            self.assertEqual(2048,p['source_bytes'])
            self.assertFalse(p['monetary_side_effects'])
            for quote in p['quote_only_examples']:
                self.assertEqual({'provider','vcpus','memory_mb','max_seconds','max_attempts','source_job_id'},set(quote))
                self.assertLessEqual(quote['vcpus'],16)
                self.assertLessEqual(quote['memory_mb'],65536)
                if quote['provider']=='cloud_run':
                    self.assertLessEqual(quote['vcpus'],8)
                    self.assertLessEqual(quote['memory_mb'],32768)
    def test_benchmark_cannot_spend_or_call_external_sources(self):
        s=read('src/ecai_index_benchmark.erl')
        for x in ['damage_cln:','ecai_compute_settings:','ecai_index_pool:','damage_ipfs:',
                  'httpc:','gun:','ecai_index_rewards:']:
            self.assertNotIn(x,s)
        for x in ['file:make_dir(Out)','corpus_sha256','query_p95_ms','first_searchable_ms',
                  'roundtrip_verified','external_network_calls => 0']:
            self.assertIn(x,s)
        self.assertIn('-extra',read('scripts/benchmark_index.sh'))

if __name__ == '__main__': unittest.main()
