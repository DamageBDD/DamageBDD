# ECAI codebase learning and continuous repair

This subsystem builds a persistent, inspectable code model for the `damage`, `ecai`, and `erm` applications, connects it to `ecai_vuln_monitor`, and generates bounded repair patches for discovered vulnerabilities.

## Modules

- `ecai_code_paths` — shared `/var/lib/damage` -> XDG state-root resolution.
- `ecai_ollama_client` — endpoint-aware Ollama HTTP client over `damage_gun`.
- `ecai_ollama_pool` — LAN worker discovery, health/model-digest tracking, leasing, failover, and role-aware scheduling.
- `ecai_code_analyser` — deterministic Erlang/BEAM/source analysis.
- `ecai_code_graph` — module call graph and neighborhoods.
- `ecai_learning_store` — DETS-backed analyses, knowledge cards, graphs, and repair history.
- `ecai_code_knowledge` — module/application/global knowledge-card synthesis.
- `ecai_codebase_learner` — incremental codebase learning loop.
- `ecai_learning_snapshot` — versioned JSON snapshot of current learned state.
- `ecai_code_context` — vulnerability-specific architectural context recovery.
- `ecai_patch_verifier` — isolated Git worktree verification.
- `ecai_patch_worker` — bounded Ollama patch/diagnostic retry loop.
- `ecai_patch_sup` — temporary repair-worker supervisor.
- `ecai_patch_manager` — continuously queues unseen open vulnerability versions.
- `ecai_code_security_sup` — subsystem supervisor.
- `ecai_codebase_learning` — operator-facing learning API.
- `ecai_code_repair` — operator-facing repair API.

The included `ecai_sup.erl` adds `ecai_code_security_sup`. The included `ecai_vuln_monitor.erl` delegates state paths to `ecai_code_paths` and tells the learner when a module has just been scanned.

## State layout

System state is preferred:

```text
/var/lib/damage
├── dets
│   ├── codebase_learning.dets
│   ├── damage_vulnerabilities.dets
│   ├── ecai_vulnerabilities.dets
│   └── erm_vulnerabilities.dets
├── git
│   └── security
│       ├── patches
│       └── worktrees
├── keys
├── logs
│   ├── codebase_learning.json
│   ├── damage_vulnerabilities.json
│   ├── ecai_vulnerabilities.json
│   └── erm_vulnerabilities.json
├── runtime
├── ssh
├── tor
└── wallets
```

Fallback order is `$XDG_STATE_HOME/damage`, then `$HOME/.local/state/damage`.

## Repository learning

Set `code_repo_root` to the DamageBDD repository root. The learner prefers `.erl` files below:

```text
apps/damage/{src,test,tests}
apps/ecai/{src,test,tests}
apps/erm/{src,test,tests}
```

If repository source is unavailable, it falls back to the modules declared by the loaded OTP applications and reads source/abstract code from their BEAMs.

Only changed source hashes or a changed configured model regenerate module knowledge cards. Module-card inference records include the selected LAN node, model, discovered digest, and timing metadata. Application/global cards are regenerated after relevant module-card changes. Module learning can run concurrently across the configured Ollama capacity while DETS remains the single authoritative store.

## Suggested sys.config entries

Merge these keys into the existing `ecai` application config:

```erlang
{code_security_enabled, true},
{code_repo_root, "/path/to/DamageBDD"},
{code_learning_interval_ms, 300000},
{code_patch_scan_interval_ms, 60000},
{code_patch_require_global_learning, true},
{code_patch_verify, true},
{code_patch_run_eunit, true},
{code_patch_max_attempts, 3},
{code_patch_keep_worktree, false},
{code_patch_command_timeout_ms, 300000},
{code_ollama_model, "qwen3-coder:30b"},
{code_ollama_timeout_ms, 180000},
{code_ollama_connect_timeout_ms, 5000},
{code_ollama_health_interval_ms, 30000},
{code_ollama_health_timeout_ms, 5000},
{code_ollama_failure_threshold, 2},
{code_ollama_cluster_attempts, 3},
{code_ollama_queue_timeout_ms, 300000},
{code_learning_parallelism, auto},
{code_ollama_nodes, [
    #{
        id => threadripper,
        host => "127.0.0.1",
        port => 11434,
        roles => [learning, synthesis, audit, patch],
        models => ["qwen3-coder:30b"],
        max_inflight => 1,
        weight => 2
    },
    #{
        id => gpu1,
        host => "192.168.1.31",
        port => 11434,
        roles => [learning, audit, patch],
        models => ["qwen3-coder:30b"],
        max_inflight => 1,
        weight => 4
    },
    #{
        id => gpu2,
        host => "192.168.1.32",
        port => 11434,
        roles => [learning, audit, patch],
        models => ["qwen3-coder:30b"],
        max_inflight => 1,
        weight => 4
    }
]}
```

The existing vulnerability monitor settings remain independent:

```erlang
{vulnerability_scan_interval_ms, 60000},
{vulnerability_rescan_unchanged, false}
```


## LAN Ollama worker pool

Each Ollama worker must be reachable from the ECAI node. Keep port `11434` restricted to a trusted LAN/VLAN or authenticated reverse proxy; Ollama's native LAN endpoint should not be exposed directly to the public Internet.

`ecai_ollama_pool` probes `/api/tags` and records the models and digests actually present on each worker. A node may optionally pin expected digests:

```erlang
#{
    id => gpu1,
    host => "192.168.1.31",
    port => 11434,
    roles => [learning, audit, patch],
    models => ["qwen3-coder:30b"],
    model_digests => #{
        "qwen3-coder:30b" => "<digest from /api/tags>"
    },
    max_inflight => 1,
    weight => 4
}
```

If the configured digest does not match the worker's `/api/tags` result, that node is marked down. Requests are leased to healthy/unknown workers that advertise the requested role and model. Failed requests are retried on another eligible node up to `code_ollama_cluster_attempts`.

Roles are intentionally separate: `learning` handles module cards, `synthesis` handles application/global cards, `audit` handles vulnerability scans, and `patch` handles repair generation. The first learning pass uses `code_learning_parallelism`; `auto` resolves to the currently configured learning capacity.

Operator visibility:

```erlang
ecai_ollama_pool:status().
ecai_ollama_pool:refresh().
ecai_ollama_pool:capacity(learning).
```

## Operator API

```erlang
%% Force an incremental repository learning pass.
ecai_codebase_learning:refresh().

%% Observe learner/store/repair state.
ecai_codebase_learning:status().

%% Write an explicit model-learning snapshot now.
ecai_codebase_learning:snapshot().
ecai_codebase_learning:snapshot_path().

%% Inspect deterministic analysis + model knowledge for one module.
ecai_codebase_learning:module(ecai, ecai_vuln_monitor).

%% Inspect graph neighborhood.
ecai_codebase_learning:related(ecai, ecai_vuln_monitor, 2).

%% Application and cross-application architecture cards.
ecai_codebase_learning:application(ecai).
ecai_codebase_learning:architecture().

%% Ask the patch manager to consume current vulnerability reports now.
ecai_code_repair:scan_now().

%% Review accumulated repair records.
ecai_code_repair:repairs().
```

For a specific finding:

```erlang
ecai_code_repair:propose(ecai, ecai_api, <<"finding-fingerprint">>).
```

## Patch safety boundary

Generated patches are never directly applied to the checked-out repository. The verifier rejects paths outside `apps/damage/`, `apps/ecai/`, and `apps/erm/`, rejects path traversal and binary patches, then creates a detached Git worktree and executes:

```text
git apply --check
git apply
git diff --check
rebar3 compile
rebar3 eunit        # configurable
```

A failed verification can be returned to Ollama for a bounded retry. Patch files and repair metadata remain under the Damage state tree.

## Learning snapshot semantics

`logs/codebase_learning.json` is the explicit model-learning snapshot. It contains source/analysis hashes, deterministic graph summaries, module knowledge cards, application/global architecture knowledge, Git identity/status, model identity, and repair history summaries. Raw source bodies are retained in DETS for context recovery but deliberately omitted from the JSON snapshot.

The Ollama model is therefore not treated as persistent memory. ECAI persists and versions the evidence and derived knowledge required to reconstruct model context at a later point.
