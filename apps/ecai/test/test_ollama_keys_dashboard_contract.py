from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def source(rel):
    return (ROOT / rel).read_text()


def test_keys_panel_is_wired_into_dashboard():
    shell = source('priv/templates/ui/dashboard/ecai_console.mustache')
    dashboard = source('src/ecai_dashboard.erl')
    assert 'data-view="keys"' in shell
    assert '{{{ollama_keys_panel}}}' in shell
    assert '/static/css/ecai-keys.css' in shell
    assert '/static/js/ecai-keys.js' in shell
    assert 'ollama_keys_panel => OllamaKeys' in dashboard


def test_key_management_routes_are_exported():
    http = source('src/ecai_ollama_keys_http.erl')
    app = source('src/ecai_app.erl')
    for route in [
        '/ecai/keys/ollama',
        '/ecai/keys/ollama/:id/rotate',
        '/ecai/keys/ollama/:id/revoke',
        '/ecai/keys/ollama/quick-config',
    ]:
        assert route in http
    assert 'ecai_ollama_keys_http' in app
    assert 'damage_auth:resolve_oauth' in http
    assert 'auth_mode := custodial' in http
    assert 'cache-control' in http and 'no-store' in http


def test_secrets_are_one_time_and_hashed_at_rest():
    store = source('src/ecai_ollama_api_keys.erl')
    assert 'crypto:strong_rand_bytes(32)' in store
    assert 'crypto:hash(sha256, Secret)' in store
    assert 'secret_hash =>' in store
    assert '<<"secret">>' not in store
    assert 'public_entry(Entry)' in store
    assert 'revoked_at_ms' in store
    assert 'last_used_at_ms' in store


def test_ollama_gateway_accepts_scoped_api_keys():
    gateway = source('src/ecai_ollama_http.erl')
    assert 'ecai_ollama_api_keys:authenticate(Token)' in gateway
    assert 'ecai_ollama_api_keys:has_scope(KeyAuth, Scope)' in gateway
    assert 'ollama_api_owner' in gateway
    assert 'action_scope(chat)' in gateway
    assert 'action_scope(generate)' in gateway


def test_quick_config_contains_supported_client_patterns():
    http = source('src/ecai_ollama_keys_http.erl')
    assert 'OLLAMA_HOST' in http
    assert 'OLLAMA_API_KEY' in http
    assert 'from ollama import Client' in http
    assert "import { Ollama } from 'ollama'" in http
    assert 'Authorization' in http
    assert '/api/chat' in http


def test_dashboard_exposes_common_key_operations():
    template = source('priv/templates/ui/dashboard/ollama_keys.mustache')
    js = source('priv/static/js/ecai-keys.js')
    for text in ['Create API key', 'Create &amp; configure client', 'Rotate', 'Revoke', 'ONE-TIME SECRET']:
        assert text in template or text in js
    assert '120000' in js
    assert 'navigator.clipboard' in js
    assert '/quick-config' in js


def test_supervision_and_safe_defaults():
    sup = source('src/ecai_sup.erl')
    app = source('src/ecai.app.src')
    assert 'maybe_ollama_key_specs()' in sup
    assert 'ecai_ollama_api_keys' in sup
    assert '{ollama_api_keys_enabled, true}' in app
    assert '{ollama_api_key_limit_per_account, 20}' in app
    assert '{ollama_api_auth_required, true}' in app
