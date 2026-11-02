# ECAI conversations: index selection and unified retrieval

## Scope and observed mismatch

On the supplied backend, Knowledge Search already calls `ecai_knowledge:search/2` using `bool_prefix` and can query public shared, Wikimedia, configured disk, and caller-owned funded indexes. `ecai_chat:infer_reply/8` was calling `ecai_knowledge:context/3`, which explicitly forces `matching => legacy`; results/failures were collapsed into a list. That difference explains how a short query can retrieve documents on the search page while the model receives no associated sources. It does not prove the Ollama endpoint is unavailable; test model status separately.

## Delivery

1. **Visual divider** — `ecai-chat-history-divider.patch` changes only `apps/ecai/priv/static/css/ecai-console.css`, using a 2px high-contrast desktop separator between chat history and thread. Mobile history remains an overlay.
2. **Conversation scope and RAG patch** — `ecai-conversation-index-scope.patch` adds a *closed-by-default* accordion after the personality bar. It reuses the existing Knowledge Search index-catalog model and CSS classes. The browser never stores scopes across identity changes.
3. **Backend integration** — `ecai_knowledge:context/4` calls the same `search/2` as Knowledge Search, using selected indexes and `matching => bool_prefix`. `context/3` is preserved for existing callers with legacy matching. The conversation code uses the new context mode and a bounded query derived from the question; the original question is still passed in full to Ollama.
4. **Authenticated message contract** — `POST /ecai/conversations/:id/messages` accepts optional `indexes` (array or `"all"`, omission means all); `ecai_knowledge:authorize_indexes/2` checks IDs and ownership **before persisting** the user turn. A normal reply echoes the resolved `selection` and returns non-sensitive `retrieval` status.
5. **Guest chat contract** — `POST /ecai/chat` accepts the same optional index selection, but only public logical indexes may be selected. Client-supplied `user_id` never provides funded-index authority. `GET /ecai/chat` advertises `retrieval.index_selection=true`; explicit filters are refused by the new frontend before POST when this capability is missing.
6. **Empty selection** — `indexes: []` means query *no knowledge index*. Conversation history may still be used; it does not imply `all`.
7. **Partial results** — Selected backend `unavailable`, `limited`, `timeout` or funded discovery failure remains visible in the reply's `retrieval.backends`/`retrieval.partial`. A partial backend failure is not presented as proof that a document does not exist. LLM responses continue through the existing `ecai_chat:call_model/5` route, which honors node-admin `ecai_llm_settings:route_chat/0` and otherwise uses the local Ollama fallback. The patch does not change provider selection, inference budgets or prompt safety controls.

The returned retrieval metadata is an observable claim about query execution, **not** a source-integrity proof. Independently verify retained source content using the existing `/ecai/knowledge/source` endpoint.

## REST examples

```sh
# Same logical catalog as Knowledge Search
curl -sS "$BASE/ecai/knowledge/indexes" | jq '{indexes,partial}'

# Selected scope is applied by the model-side retrieval worker
curl -sS "$BASE/ecai/conversations/$CONVERSATION_ID/messages" \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  --data '{"message":"What is an orbital orchard?","indexes":["public-ipfs"]}' \
  | jq '{reply,selection,retrieval}'

# Unfiltered existing callers still work
curl -sS "$BASE/ecai/chat" -H 'Content-Type: application/json' \
  --data '{"message":"What is ECAI?","indexes":[]}' | jq .
```

Using `"indexes":[]` in guest chat deliberately disables knowledge retrieval (not generation). `"indexes":"all"` and omission both mean accessible indexes; do not use a client-supplied owner/address as authority.

## Verification and rollout

```sh
# Apply both patches from repository root after `git apply --check`
rebar3 compile
rebar3 eunit --module=ecai_knowledge_indexes_tests
node --test apps/ecai/test/conversation_indexes_model.test.mjs \
                 apps/ecai/test/knowledge_indexes_model.test.mjs \
                 apps/ecai/test/knowledge_search_model.test.mjs
# Additional isolated tests (requires Erlang and project's compiled dependencies)
bash apps/ecai/test/personalities/chat/run.sh
bash apps/ecai/test/conversation_personalities/run.sh
```

Then restart ECAI to load changed BEAM files and hard-refresh the browser. Test: expand the conversation accordion, clear selection, select only `public-ipfs`, ask for an indexed term, and verify the API `selection.indexes` and `retrieval.backends` refer only to `public-ipfs`. Try a missing or another account's funded ID; it must be rejected rather than broadening scope. Switch accounts and ensure the scope resets. Confirm that a query found in Knowledge Search supplies source text into the model prompt and the transcript shows source-count/status.

## Limitations and future steps

- Conversational questions are tokenized and bounded before `bool_prefix` retrieval; the underlying search engine uses AND semantics. This is not semantic/vector retrieval, hybrid reranking, spell correction or document summarization. Questions that share few exact indexed words may still produce no hits.
- Full model answers require a configured and reachable backend on the existing `call_model/5` route (provider pool or local Ollama fallback). A healthy Knowledge Search endpoint alone does not confirm inference.
- Text is retrieved as *preview content* for the model; source verification requires the independent retrieval endpoint. This patch does not attach signed proof cards for every model citation.
- Index selection is scoped to the current browser session, not persisted in a conversation row. Assistant message metadata records the resolved selection so history remains auditable. Reopening a thread uses the current browser selection unless changed.
- EUnit and live-model tests must run on your Erlang node. The offline browser tests use fixture responses and cannot prove a real model generated a grounded answer.
