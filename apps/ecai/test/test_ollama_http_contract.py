#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src"


def read(name):
    return (SRC / name).read_text(encoding="utf-8")


def test_routes_are_native_ollama_paths():
    src = read("ecai_ollama_http.erl")
    for path in ("/api/tags", "/api/show", "/api/chat", "/api/generate", "/api/version", "/api/ps"):
        assert f'"{path}"' in src


def test_gateway_is_damage_auth_protected_by_default():
    src = read("ecai_ollama_http.erl")
    app = read("ecai.app.src")
    assert "damage_http:is_authorized" in src
    assert "ollama_api_auth_required, true" in src
    assert "{ollama_api_auth_required, true}" in app


def test_managed_pool_has_interactive_role_and_native_entrypoints():
    src = read("ecai_ollama_pool.erl")
    assert re.search(r"-define\(ROLES,\s*\[[^\]]*chat", src)
    assert "native_chat/3" in src
    assert "native_generate/3" in src
    assert "ecai_ollama_client:native_chat_with_meta" in src
    assert "ecai_ollama_client:native_generate_with_meta" in src


def test_client_preserves_native_ollama_payload_and_forces_accounted_completion():
    src = read("ecai_ollama_client.erl")
    assert 'Path = case Kind of' in src
    assert 'chat -> "/api/chat"' in src
    assert 'generate -> "/api/generate"' in src
    assert 'json_put(<<"stream">>, false' in src
    assert 'jsx:encode(Request)' in src


def test_ecai_tags_and_aliases_are_exposed():
    src = read("ecai_ollama_model_registry.erl")
    for tag in ("-rag-v1", "-code-v1", "-strict-v1", "ecai/chat:latest", "ecai/code:latest"):
        assert tag in src


def test_wrapper_does_not_trigger_unmanaged_embedding_rerank():
    http = read("ecai_ollama_http.erl")
    rag = read("ecai_ollama_rag.erl")
    assert "retrieve_sources_lexical" in http
    assert "retrieve_sources_lexical/3" in rag
    assert "ecai_ollama_rag:retrieve_sources(Dir, Query" not in http


def test_app_wires_gateway_conditionally():
    src = read("ecai_app.erl")
    assert "ollama_api_handlers()" in src
    assert "true -> [ecai_ollama_keys_http, ecai_ollama_http]" in src


if __name__ == "__main__":
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]
    for test in tests:
        test()
    print(f"{len(tests)} Ollama HTTP contract tests passed")
