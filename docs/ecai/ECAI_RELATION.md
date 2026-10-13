# ECAI relation core

This bundle adds a first deterministic relation layer above the current ECAI
domain-separated hash-to-curve API.

## Modules

- `ecai_relation` — canonical typed triples, stable identities, EC point mapping,
  and conversion from `ecai_code_analyser` / `ecai_code_graph`.
- `ecai_transform` — experimental affine endpoint deltas and relation-class
  distance measurements. These are measurements, **not claimed semantic
  invariants**.
- `ecai_compose` — deterministic structural composition with inspectable proof
  maps and `llm_used => false`.
- `ecai_relation_bench` — simple hidden-relation recovery metrics.

## Example

```erlang
Analysis = #{
    application => erm,
    module => erm_mpv,
    exports => [{play, 1}],
    remote_calls => [#{module => jsx, function => encode, arity => 1}],
    behaviours => [gen_server],
    includes => []
},

Relations0 = ecai_relation:from_analysis(erm, Analysis),
Relations = ecai_compose:closure(Relations0, 3),

ecai_compose:derive(Relations0, erm_mpv, uses, 3).
%% => relation erm_mpv --uses--> jsx with deterministic proof
```

## Integration

Copy the files into the matching `apps/ecai/src` and `apps/ecai/test`
directories, then run:

```sh
rebar3 compile
rebar3 eunit --module=ecai_relation_tests
rebar3 eunit --module=ecai_compose_tests
rebar3 eunit --module=ecai_transform_tests
rebar3 eunit --module=ecai_relation_bench_tests
```

`ecai_relation:point/1`, `entity_point/1`, and `ecai_transform:affine_delta/1`
require the current two-arity `ecai:hash_to_curve_point/2` NIF wrapper. The
canonicalization/composition tests do not.
