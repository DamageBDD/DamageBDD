-module(ecai_content).

-export([
    generate/0, generate/1,
    run/0, run/1,
    publish/1,
    retry/1,
    resume/0,
    learning_updated/0,
    job/1,
    jobs/0,
    status/0,
    artifact_dir/1
]).

generate() -> ecai_content_manager:generate().
generate(Scope) -> ecai_content_manager:generate(Scope).
run() -> ecai_content_manager:run().
run(Scope) -> ecai_content_manager:run(Scope).
publish(JobId) -> ecai_content_manager:publish(JobId).
retry(JobId) -> ecai_content_manager:retry(JobId).
resume() -> ecai_content_manager:resume().
learning_updated() -> ecai_content_manager:learning_updated().
job(JobId) -> ecai_content_store:get_job(JobId).
jobs() -> ecai_content_store:jobs().
status() ->
    #{
        manager => ecai_content_manager:status(),
        store => ecai_content_store:status(),
        blossom_server => ecai_blossom_client:default_server()
    }.
artifact_dir(JobId) -> ecai_content_store:artifact_dir(JobId).
