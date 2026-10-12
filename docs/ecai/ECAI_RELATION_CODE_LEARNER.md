# ECAI relation-learning integration

Apply after the `ecai_relation_core` commit.

```sh
git apply --check ecai_relation_learning_integration.patch
git apply ecai_relation_learning_integration.patch
rebar3 compile
rebar3 eunit --module=ecai_relation_learning_tests
```

The code learner now:

1. builds each application graph,
2. materialises and persists deterministic relations and relation keys,
3. builds an `all` cross-application relation set,
4. runs an indexed structural `uses` holdout benchmark when code changed or no benchmark exists,
5. writes relation-set digests and thin benchmark summaries into the learning snapshot.

Defaults:

- `relation_benchmark_enabled = true`
- `relation_benchmark_holdout = 1000`

Operator API:

```erlang
ecai_codebase_learning:refresh_relations().
ecai_codebase_learning:relations().
ecai_codebase_learning:relation_keys().
ecai_codebase_learning:run_relation_benchmark().
ecai_codebase_learning:run_relation_benchmark(1000).
ecai_codebase_learning:relation_benchmark().
```
