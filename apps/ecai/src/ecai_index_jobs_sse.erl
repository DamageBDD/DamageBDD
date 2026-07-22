%%--------------------------------------------------------------------
%% Server-Sent Events stream for indexing job progress.
%%--------------------------------------------------------------------
-module(ecai_index_jobs_sse).

-export([init/2]).

-define(HEARTBEAT_MS, 15000).
-define(REPLAY_LIMIT, 10000).

init(Req0, State) ->
    case authorize(Req0, State) of
        {ok, Req1, State1} ->
            stream_job(Req1, State1);
        {error, Req1, State1} ->
            Req2 = cowboy_req:reply(401, Req1),
            {ok, Req2, State1}
    end.

stream_job(Req0, State) ->
    JobId = cowboy_req:binding(id, Req0),
    case safe_get_job(JobId) of
        {ok, Job} ->
            case authorized_for_job(Job, State) of
                true -> stream_authorized_job(JobId, Req0, State);
                false ->
                    Body = jsx:encode(#{ok => false, error => <<"forbidden">>}),
                    Req1 = cowboy_req:reply(
                        403,
                        #{<<"content-type">> => <<"application/json">>},
                        Body,
                        Req0
                    ),
                    {ok, Req1, State}
            end;
        {error, not_found} ->
            Body = jsx:encode(#{ok => false, error => <<"not_found">>}),
            Req1 = cowboy_req:reply(
                404,
                #{<<"content-type">> => <<"application/json">>},
                Body,
                Req0
            ),
            {ok, Req1, State};
        {error, Reason} ->
            Body = jsx:encode(#{
                ok => false,
                error => ecai_index_job_codec:externalize(Reason)
            }),
            Req1 = cowboy_req:reply(
                503,
                #{<<"content-type">> => <<"application/json">>},
                Body,
                Req0
            ),
            {ok, Req1, State}
    end.

stream_authorized_job(JobId, Req0, State) ->
    LastSeq0 = requested_last_sequence(Req0),
    Headers = #{
        <<"content-type">> => <<"text/event-stream">>,
        <<"cache-control">> => <<"no-cache">>,
        <<"connection">> => <<"keep-alive">>,
        <<"x-accel-buffering">> => <<"no">>
    },
    Req1 = cowboy_req:stream_reply(200, Headers, Req0),
    ok = ecai_index_job_events:subscribe(JobId, self()),
    try
        {LastSeq1, ReplayedTerminal} = replay(JobId, LastSeq0, Req1),
        case ReplayedTerminal orelse current_job_is_terminal(JobId) of
            true -> cowboy_req:stream_body(<<>>, fin, Req1);
            false -> stream_loop(JobId, LastSeq1, Req1)
        end
    catch
        _Class:_Reason -> ok
    after
        _ = ecai_index_job_events:unsubscribe(JobId, self())
    end,
    {ok, Req1, State}.

replay(JobId, LastSeq, Req) ->
    replay_pages(JobId, LastSeq, Req, false).

replay_pages(JobId, LastSeq, Req, Terminal0) ->
    case ecai_index_jobs_srv:events(JobId, LastSeq, ?REPLAY_LIMIT) of
        {ok, Events} ->
            {NextSeq, Terminal1} = lists:foldl(
                fun(Event, {AccSeq, AccTerminal}) ->
                    Seq = event_seq(Event),
                    case Seq > AccSeq of
                        true ->
                            ok = send_event(Event, Req),
                            {Seq, AccTerminal orelse terminal_event(Event)};
                        false ->
                            {AccSeq, AccTerminal}
                    end
                end,
                {LastSeq, Terminal0},
                Events
            ),
            case {Terminal1, length(Events), NextSeq > LastSeq} of
                {true, _Count, _Advanced} -> {NextSeq, true};
                {false, ?REPLAY_LIMIT, true} ->
                    replay_pages(JobId, NextSeq, Req, false);
                _ ->
                    {NextSeq, false}
            end;
        {error, _Reason} ->
            {LastSeq, Terminal0}
    end.

stream_loop(JobId, LastSeq, Req) ->
    receive
        {ecai_index_job_event, JobId, Event} ->
            Seq = event_seq(Event),
            case Seq > LastSeq of
                true ->
                    ok = send_event(Event, Req),
                    case terminal_event(Event) of
                        true -> cowboy_req:stream_body(<<>>, fin, Req);
                        false -> stream_loop(JobId, Seq, Req)
                    end;
                false ->
                    stream_loop(JobId, LastSeq, Req)
            end
    after ?HEARTBEAT_MS ->
        ok = cowboy_req:stream_body(<<": heartbeat\n\n">>, nofin, Req),
        stream_loop(JobId, LastSeq, Req)
    end.

send_event(Event0, Req) ->
    Event = ecai_index_job_codec:externalize(Event0),
    Seq = event_seq(Event),
    Type = event_type(Event),
    Payload = jsx:encode(Event),
    Frame = iolist_to_binary([
        "id: ", integer_to_binary(Seq), "\n",
        "event: ", Type, "\n",
        "data: ", Payload, "\n\n"
    ]),
    cowboy_req:stream_body(Frame, nofin, Req).

event_seq(Event) ->
    maps:get(seq, Event, maps:get(<<"seq">>, Event, 0)).

event_type(Event) ->
    maps:get(type, Event, maps:get(<<"type">>, Event, <<"message">>)).

terminal_event(Event) ->
    State = maps:get(state, Event, maps:get(<<"state">>, Event, <<>>)),
    lists:member(
        State,
        [
            <<"paused">>,
            <<"canceled">>,
            <<"failed">>,
            <<"completed">>,
            <<"ready_to_mint">>,
            <<"minted">>
        ]
    ).

current_job_is_terminal(JobId) ->
    case safe_get_job(JobId) of
        {ok, Job} ->
            State = maps:get(<<"state">>, Job, <<>>),
            lists:member(
                State,
                [
                    <<"paused">>,
                    <<"canceled">>,
                    <<"failed">>,
                    <<"completed">>,
                    <<"ready_to_mint">>,
                    <<"minted">>
                ]
            );
        {error, _Reason} ->
            true
    end.

requested_last_sequence(Req) ->
    Header = cowboy_req:header(<<"last-event-id">>, Req, undefined),
    Query = cowboy_req:match_qs([{after_seq, [], undefined}], Req),
    QueryValue = maps:get(after_seq, Query, undefined),
    parse_nonnegative_integer(
        case Header of
            undefined -> QueryValue;
            _ -> Header
        end,
        0
    ).

parse_nonnegative_integer(undefined, Default) -> Default;
parse_nonnegative_integer(Bin, Default) when is_binary(Bin) ->
    try binary_to_integer(Bin) of
        Value when Value >= 0 -> Value;
        _ -> Default
    catch
        error:badarg -> Default
    end;
parse_nonnegative_integer(_Other, Default) -> Default.

safe_get_job(JobId) ->
    try ecai_index_jobs_srv:get(JobId) of
        Result -> Result
    catch
        exit:Reason -> {error, {index_jobs_unavailable, Reason}}
    end.

authorized_for_job(Job, State) ->
    case authenticated_owner(State) of
        undefined -> true;
        Owner ->
            Spec = maps:get(<<"spec">>, Job, #{}),
            maps:get(<<"owner">>, Spec, <<>>) =:= Owner
    end.

authenticated_owner(State) ->
    case maps:get(ae_account, State, maps:get(owner, State, undefined)) of
        AuthBin when is_binary(AuthBin), byte_size(AuthBin) > 0 -> AuthBin;
        List when is_list(List), List =/= [] ->
            try unicode:characters_to_binary(List) of
                Converted when is_binary(Converted), byte_size(Converted) > 0 -> Converted
            catch
                _Class:_Reason -> undefined
            end;
        _ -> undefined
    end.

authorize(Req, State) ->
    try damage_http:is_authorized(Req, State) of
        {true, Req1, State1} -> {ok, Req1, State1};
        {false, Req1, State1} -> {error, Req1, State1};
        {{false, _Challenge}, Req1, State1} -> {error, Req1, State1};
        _Other -> {error, Req, State}
    catch
        _Class:_Reason -> {error, Req, State}
    end.
