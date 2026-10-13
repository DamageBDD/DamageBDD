-module(ecai_content_worker).

-export([run/1]).

run(JobId0) ->
    JobId = ecai_content_util:to_binary(JobId0),
    case ecai_content_store:get_job(JobId) of
        {ok, Job0} ->
            _ = ecai_content_store:update_job(JobId, #{status => running, last_error => undefined}),
            advance(Job0);
        not_found ->
            {error, {job_not_found, JobId}};
        {error, _} = Error ->
            Error
    end.

advance(Job = #{stage := evidence_ready}) ->
    with_job(Job, generation, fun generate_stage/1);
advance(Job = #{stage := generated}) ->
    with_job(Job, validation, fun validate_stage/1);
advance(Job = #{stage := validated}) ->
    with_job(Job, rendering, fun render_stage/1);
advance(Job = #{stage := rendered}) ->
    case publish_requested(Job) of
        true -> with_job(Job, blossom_upload, fun blossom_stage/1);
        false -> finish_waiting(Job)
    end;
advance(Job = #{stage := media_uploaded}) ->
    with_job(Job, nostr_prepare, fun nostr_prepare_stage/1);
advance(Job = #{stage := nostr_prepared}) ->
    with_job(Job, nostr_publish, fun nostr_stage/1);
advance(Job = #{stage := nostr_published}) ->
    with_job(Job, linkedin_publish, fun linkedin_stage/1);
advance(Job = #{stage := linkedin_published}) ->
    complete(Job);
advance(Job = #{stage := complete}) ->
    {ok, Job};
advance(Job) ->
    fail(Job, {unknown_stage, maps:get(stage, Job, undefined)}).

with_job(Job, Operation, Fun) ->
    try Fun(Job) of
        {ok, NextJob} -> advance(NextJob);
        {stop, NextJob} -> {ok, NextJob};
        {error, Reason} -> fail(Job, {Operation, Reason})
    catch
        Class:Reason:Stack -> fail(Job, {Operation, {exception, Class, Reason, Stack}})
    end.

generate_stage(Job) ->
    Evidence = maps:get(evidence, Job),
    Opts = maps:get(options, Job, #{}),
    case ecai_content_generator:generate(Evidence, Opts) of
        {ok, Pack} ->
            case write_pack_artifacts(maps:get(id, Job), Pack) of
                ok -> update(Job, #{stage => generated, content => Pack});
                {error, _} = Error -> Error
            end;
        {error, _} = Error ->
            Error
    end.

validate_stage(Job) ->
    Pack = maps:get(content, Job),
    Evidence = maps:get(evidence, Job),
    case ecai_content_validator:validate(Pack, Evidence) of
        ok ->
            update(Job, #{
                stage => validated,
                validation => #{status => ok, at => ecai_content_util:now_iso8601()}
            });
        {error, _} = Error ->
            Error
    end.

render_stage(Job) ->
    Pack = maps:get(content, Job),
    ImageSpec = ecai_content_util:mget(<<"image">>, Pack, #{}),
    Opts = maps:get(options, Job, #{}),
    ImageOpts = maps:get(image, Opts, #{}),
    case ecai_image_renderer:render(maps:get(id, Job), ImageSpec, ImageOpts) of
        {ok, ImageMeta} -> update(Job, #{stage => rendered, image => ImageMeta});
        {error, _} = Error -> Error
    end.

blossom_stage(Job) ->
    Image = maps:get(image, Job),
    Opts = maps:get(options, Job, #{}),
    BlossomOpts = maps:get(blossom, Opts, #{}),
    Path = maps:get(path, Image),
    case ecai_blossom_client:upload(Path, BlossomOpts#{mime_type => maps:get(mime_type, Image)}) of
        {ok, Descriptor} -> update(Job, #{stage => media_uploaded, blossom => Descriptor});
        {error, _} = Error -> Error
    end.

nostr_prepare_stage(Job) ->
    case application:get_env(ecai, content_nostr_enabled, true) of
        false ->
            update(Job, #{stage => nostr_published, nostr => #{skipped => disabled}});
        true ->
            Pack = maps:get(content, Job),
            Media = maps:get(blossom, Job),
            Opts = maps:get(options, Job, #{}),
            case ecai_nostr_content:prepare(Pack, Media, maps:get(nostr, Opts, #{})) of
                {ok, Signed} -> update(Job, #{stage => nostr_prepared, nostr_event => Signed});
                {error, _} = Error -> Error
            end
    end.

nostr_stage(Job) ->
    Signed = maps:get(nostr_event, Job),
    Opts = maps:get(options, Job, #{}),
    case ecai_nostr_content:publish_signed(Signed, maps:get(nostr, Opts, #{})) of
        {ok, Receipt} -> update(Job, #{stage => nostr_published, nostr => Receipt});
        {error, _} = Error -> Error
    end.

linkedin_stage(Job) ->
    case application:get_env(ecai, content_linkedin_enabled, false) of
        false ->
            update(Job, #{stage => linkedin_published, linkedin => #{skipped => disabled}});
        true ->
            Opts = maps:get(options, Job, #{}),
            case
                ecai_linkedin_client:publish_image_post(
                    maps:get(content, Job), maps:get(image, Job), maps:get(linkedin, Opts, #{})
                )
            of
                {ok, Receipt} -> update(Job, #{stage => linkedin_published, linkedin => Receipt});
                {error, _} = Error -> Error
            end
    end.

finish_waiting(Job) ->
    case ecai_content_store:update_job(maps:get(id, Job), #{status => awaiting_publish}) of
        {ok, Next} -> {stop, Next};
        {error, _} = Error -> Error
    end.

complete(Job) ->
    case
        ecai_content_store:update_job(maps:get(id, Job), #{
            status => complete,
            stage => complete,
            completed_at => ecai_content_util:now_iso8601()
        })
    of
        {ok, Next} -> {ok, Next};
        {error, _} = Error -> Error
    end.

fail(Job, Reason) ->
    JobId = maps:get(id, Job),
    RetryCount = maps:get(retry_count, Job, 0) + 1,
    Status =
        case linkedin_ambiguous(Reason) of
            true -> manual_reconcile;
            false -> retry
        end,
    _ = ecai_content_store:update_job(JobId, #{
        status => Status,
        retry_count => RetryCount,
        last_error => sanitize_reason(Reason),
        last_failed_at => ecai_content_util:now_iso8601()
    }),
    {error, Reason}.

linkedin_ambiguous({linkedin_publish, {linkedin_post_ambiguous, _}}) -> true;
linkedin_ambiguous(_) -> false.

update(Job, Patch) ->
    ecai_content_store:update_job(maps:get(id, Job), Patch).

publish_requested(Job) ->
    maps:get(publish_requested, Job, false) orelse
        application:get_env(ecai, content_auto_publish, false).

write_pack_artifacts(JobId, Pack) ->
    Files = [
        {<<"content.json">>, jsx:encode(ecai_content_util:json_safe(Pack))},
        {<<"article.md">>, ecai_content_util:mget(<<"article_markdown">>, Pack, <<>>)},
        {<<"docs.md">>, ecai_content_util:mget(<<"documentation_markdown">>, Pack, <<>>)},
        {<<"linkedin.txt">>,
            ecai_content_util:mget(
                <<"commentary">>, ecai_content_util:mget(<<"linkedin">>, Pack, #{}), <<>>
            )},
        {<<"image-prompt.txt">>,
            ecai_content_util:mget(
                <<"prompt">>, ecai_content_util:mget(<<"image">>, Pack, #{}), <<>>
            )}
    ],
    write_files(JobId, Files).

write_files(_JobId, []) ->
    ok;
write_files(JobId, [{Name, Data} | Rest]) ->
    case ecai_content_store:artifact_path(JobId, Name) of
        {ok, Path} ->
            case ecai_content_util:atomic_write(Path, Data) of
                ok -> write_files(JobId, Rest);
                {error, _} = Error -> Error
            end;
        {error, _} = Error ->
            Error
    end.

sanitize_reason(Reason) -> ecai_content_util:to_binary(io_lib:format("~p", [Reason])).
