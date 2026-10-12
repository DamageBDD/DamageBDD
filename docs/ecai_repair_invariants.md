# ECAI invariant capsules for code learning and repair

This change places a deterministic, content-addressed repair capsule between the
source-pinned repair context and the existing model provider. It does not replace
the existing Ollama/OpenAI routing, worktree management, compiler, or test runner.

## Runtime flow

1. The repair job pins a Git worktree and constructs its normal request.
2. `ecai_repair_bridge` extracts the target files and builds a bounded repair
   closure containing the target module, referenced tests, callers and remote
   callees.
3. `ecai_repair_capsule` canonicalizes the problem, commit, source hashes, API
   facts and policy. Its SHA-256 ID is stable across worktree locations. When the
   core `ecai` module exports a recognized hash-to-point function, the envelope
   also records a native ECAI point commitment.
4. The exact capsule is persisted, attached to request metadata and inserted as
   a protected system context before any Ollama or OpenAI attempt.
5. The provider returns only a candidate. Existing compile/test verification runs
   first. On success, `ecai_repair_verify` additionally checks the capsule ID,
   pinned commit, allowed-file boundary, source hashes and public Erlang API.
6. Verified patch evidence is persisted by problem fingerprint. Repeated matching
   evidence can be inspected with `ecai_repair_learning:promotable/3`; model output
   is never promoted merely because it was generated.

## Added modules

- `ecai_code_invariants`: extracts modules, exports, specs, callbacks, behaviours,
  calls, source hashes and a bounded repair closure.
- `ecai_repair_capsule`: canonical capsule schema, ID, encoding and validation.
- `ecai_repair_commitment`: optional bridge to native ECAI point mapping.
- `ecai_repair_prompt`: bounded, prompt-injection-aware rendering.
- `ecai_repair_bridge`: transparent request enrichment and post-verification hook.
- `ecai_repair_verify`: deterministic scope and API checks.
- `ecai_repair_store`: atomic durable capsule/event storage.
- `ecai_repair_learning`: verified evidence lookup and promotion thresholding.
- `ecai_repair_inference`: provider-neutral Ollama/OpenAI adapter.
- `ecai_invariant_repair`: explicit public facade for callers outside the current
  repair worker.

## Public facade

```erlang
Problem = #{
    class => compiler_warning,
    file => <<"apps/ecai/src/ecai_nft.erl">>,
    diagnostic => <<"deprecated catch expression">>
},

{ok, Prepared} = ecai_invariant_repair:prepare(
    Worktree,
    Problem,
    #{
        state_root => <<"/var/lib/damage/ecai">>,
        allowed_files => [<<"apps/ecai/src/ecai_nft.erl">>]
    }
),

%% Uses the current provider pool unless inference_fun/inference_adapter is set.
{ok, Candidate} = ecai_invariant_repair:infer(Prepared, #{}).
```

The existing provider path is wrapped automatically. Detection record:

```text
score=248
module=apps/ecai/src/ecai_patch_worker.erl
function=attach_inference_state
arities=[2]
```

The existing deterministic verifier is wrapped automatically. Detection record:

```text
apps/ecai/src/ecai_patch_verifier.erl verify arities [1, 2]
```

## Request keys recognized by the bridge

The bridge recognizes `repo`, `repo_path`, `worktree`, `checkout` or
`source_root`; `problem`, `failure`, `diagnostic`, `error` or `repair_request`;
and `allowed_files`, `permitted_files`, `base_commit`, `source_commit`,
`pinned_commit`, `state_root`, `prompt`, `messages` and `metadata`.

A request is treated as repair work when its task is `repair`, `code_repair`,
`patch`, `fix` or `learning_repair`, or when it carries a structured failure or
repair request. Non-repair provider traffic is unchanged.

## Verification boundary

Cryptographic commitment proves that the capsule was not changed after creation;
it does not prove that a source proposition or generated patch is semantically
correct. Compilation, tests and explicit invariant checks remain required.

## Tests

```sh
rebar3 compile
rebar3 eunit --module=ecai_repair_capsule_tests
```
