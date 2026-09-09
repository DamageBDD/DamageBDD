%%%-------------------------------------------------------------------
%%% @doc Bounded NIP-01 relay snapshots. Run outside the UI process.
%%%
%%% This module intentionally uses only Gun APIs known to be present in the
%%% surrounding Damage/ERM tree: gun:ws_upgrade/3 and gun:ws_send/3.
%%% Connection exceptions retain the missing MFA in diagnostics so local API
%%% mismatches are not misreported as remote relay failures.
%%%-------------------------------------------------------------------
-module(erm_lens_relay).

-ifdef(TEST).
-export([collect/8, await_ok/4]).
-endif.

-include_lib("kernel/include/logger.hrl").

-export([fetch/2, publish/2]).

-define(CONNECT_TIMEOUT, 6000).
-define(UPGRADE_TIMEOUT, 6000).
-define(QUERY_TIMEOUT, 10000).
-define(PUBLISH_TIMEOUT, 8000).
-define(MAX_FRAME_BYTES, 262144).

fetch(Url, C) ->
    with_connection(Url, fun(Pid, Stream) ->
        Now = erlang:system_time(second),
        Since = Now - erm_lens_config:integer(window_seconds, C, 172800, 1, 604800),
        BasePosts = #{<<"since">> => Since, <<"until">> => Now, <<"limit">> => 150},
        Filters = [
            BasePosts#{<<"kinds">> => [20]},
            BasePosts#{<<"kinds">> => [1]}
        ],
        {PostCount, Rejected, PostsEnd} = query(Pid, Stream, <<"lens-posts">>, Filters, 450),
        Ids = erm_lens_feed:ids(),
        Engagement =
            case Ids of
                [] ->
                    {0, 0, skipped};
                _ ->
                    Base = #{<<"since">> => Since, <<"until">> => Now, <<"limit">> => 500},
                    query(
                        Pid,
                        Stream,
                        <<"lens-engagement">>,
                        [
                            Base#{<<"kinds">> => [7, 6, 16, 1, 5], <<"#e">> => Ids},
                            Base#{<<"kinds">> => [1111], <<"#E">> => Ids}
                        ],
                        1100
                    )
            end,
        {EC, ER, EngagementEnd} = Engagement,
        {ok, #{
            posts_received => PostCount,
            engagement_received => EC,
            rejected => Rejected + ER,
            sampled_at => Now,
            coverage => bounded_sample,
            posts_end => PostsEnd,
            engagement_end => EngagementEnd,
            complete => PostsEnd =:= eose andalso
                        (EngagementEnd =:= eose orelse EngagementEnd =:= skipped)
        }}
    end).

publish(Url, Event) ->
    case erm_lens_nostr:verify(Event) of
        ok ->
            with_connection(Url, fun(Pid, Stream) ->
                ok = require_send(send_frame(Pid, Stream, [<<"EVENT">>, erm_lens_nostr:event_fields(Event)])),
                await_ok(Pid, Stream, maps:get(<<"id">>, Event), deadline(?PUBLISH_TIMEOUT))
            end);
        Error ->
            Error
    end.

with_connection(Url, Fun) ->
    try
        {Host, Port, Path, TlsOpts} = relay_target(Url),
        ?LOG_DEBUG("ERM Lens relay connecting endpoint=~ts", [
            erm_lens_diagnostics:relay_label(Url)
        ]),
        case
            safe_gun_open(Host, Port, #{
                transport => tls,
                protocols => [http],
                retry => 0,
                connect_timeout => 5000,
                tls_opts => TlsOpts,
                ws_opts => websocket_options()
            })
        of
            {ok, Pid} ->
                ConnMon = erlang:monitor(process, Pid),
                try
                    case safe_await_up(Pid) of
                        {ok, http} -> upgrade_and_run(Url, Pid, Path, Fun);
                        {ok, Protocol} -> {error, {invalid_ws_protocol, Protocol}};
                        {error, _} = Error -> Error
                    end
                after
                    safe_close(Pid),
                    erlang:demonitor(ConnMon, [flush])
                end;
            {error, _} = Error ->
                Error
        end
    catch
        error:undef:Stacktrace ->
            MFA = undef_mfa(Stacktrace),
            ?LOG_ERROR(
                "ERM Lens relay local API unavailable url=~p mfa=~p stack=~p",
                [erm_lens_diagnostics:relay_label(Url), MFA, stack_head(Stacktrace)]
            ),
            {error, {relay_api_undefined, MFA}};
        Class:Reason:Stacktrace ->
            ?LOG_WARNING(
                "ERM Lens relay connection exception url=~p error=~p:~p stack=~p",
                [erm_lens_diagnostics:relay_label(Url), Class, safe_reason(Reason), stack_head(Stacktrace)]
            ),
            {error, {relay_failed, Class, safe_reason(Reason)}}
    end.

relay_target(Url) ->
    case erm_lens_config:relay(Url) of
        true -> ok;
        false -> error(invalid_relay_url)
    end,
    #{scheme := <<"wss">>, host := Host} = U = uri_string:parse(Url),
    false = maps:is_key(userinfo, U),
    HostList = binary_to_list(Host),
    Port = maps:get(port, U, 443),
    Path0 = maps:get(path, U, <<"/">>),
    Path1 =
        case Path0 of
            <<>> -> <<"/">>;
            _ -> Path0
        end,
    Path =
        case maps:find(query, U) of
            {ok, Q} -> <<Path1/binary, "?", Q/binary>>;
            error -> Path1
        end,
    TLS = [
        {verify, verify_peer},
        {cacerts, public_key:cacerts_get()},
        {server_name_indication, HostList},
        {customize_hostname_check, [
            {match_fun, public_key:pkix_verify_hostname_match_fun(https)}
        ]}
    ],
    {HostList, Port, Path, TLS}.

safe_gun_open(Host, Port, Opts) ->
    try gun:open(Host, Port, Opts) of
        {ok, Pid} when is_pid(Pid) -> {ok, Pid};
        {error, Reason} -> {error, {open_failed, safe_reason(Reason)}};
        _ -> {error, unexpected_gun_open_result}
    catch
        error:undef:Stack -> erlang:raise(error, undef, Stack);
        exit:{noproc, _} -> {error, gun_not_started};
        Class:Reason -> {error, {gun_open_failed, Class, safe_reason(Reason)}}
    end.

safe_await_up(Pid) ->
    try gun:await_up(Pid, ?CONNECT_TIMEOUT) of
        {ok, Protocol} -> {ok, Protocol};
        {error, Reason} -> {error, {await_up_failed, safe_reason(Reason)}};
        _ -> {error, unexpected_await_up_result}
    catch
        error:undef:Stack -> erlang:raise(error, undef, Stack);
        Class:Reason -> {error, {await_up_failed, Class, safe_reason(Reason)}}
    end.

upgrade_and_run(Url, Pid, Path, Fun) ->
    %% Gun in this repository exposes ws_upgrade/3, not ws_upgrade/4.
    Stream = gun:ws_upgrade(Pid, Path, []),
    receive
        {gun_upgrade, Pid, Stream, [<<"websocket">>], _RespHeaders} ->
            ?LOG_DEBUG("ERM Lens relay websocket ready endpoint=~ts", [erm_lens_diagnostics:relay_label(Url)]),
            Fun(Pid, Stream);
        {gun_response, Pid, Stream, _Fin, Status, _RespHeaders} ->
            {error, {upgrade_rejected, Status}};
        {gun_ws, Pid, Stream, close} ->
            {error, {upgrade_closed, close}};
        {gun_ws, Pid, Stream, {close, Code, Reason}} ->
            {error, {upgrade_closed, Code, safe_reason(Reason)}};
        {gun_ws, Pid, Stream, {close, Reason}} ->
            {error, {upgrade_closed, safe_reason(Reason)}};
        {gun_error, Pid, Stream, Why} ->
            {error, {upgrade_failed, safe_reason(Why)}};
        {gun_error, Pid, Why} ->
            {error, {upgrade_failed, safe_reason(Why)}};
        {'DOWN', _Mon, process, Pid, Why} ->
            {error, {relay_down, safe_reason(Why)}};
        {gun_down, Pid, _Protocol, Reason, _Killed, _Unprocessed} ->
            {error, {gun_down, safe_reason(Reason)}};
        {gun_down, Pid, _Protocol, Reason, _Killed} ->
            {error, {gun_down, safe_reason(Reason)}}
    after ?UPGRADE_TIMEOUT ->
        {error, upgrade_timeout}
    end.

query(Pid, Stream, Sub, Filters, Cap) ->
    ok = require_send(send_frame(Pid, Stream, [<<"REQ">>, Sub | Filters])),
    try
        collect(Pid, Stream, Sub, Filters, Cap, deadline(?QUERY_TIMEOUT), 0, 0)
    after
        _ = send_frame(Pid, Stream, [<<"CLOSE">>, Sub])
    end.

collect(_Pid, _Stream, _Sub, _Filters, 0, _End, N, Bad) ->
    {N, Bad, cap};
collect(Pid, Stream, Sub, Filters, Left, End, N, Bad) ->
    case remaining(End) of
        0 -> error({relay_query_timeout, N, Bad});
        _ -> collect_message(Pid, Stream, Sub, Filters, Left, End, N, Bad)
    end.

collect_message(Pid, Stream, Sub, Filters, Left, End, N, Bad) ->
    receive
        {gun_ws, Pid, Stream, {text, Data}} when byte_size(Data) =< ?MAX_FRAME_BYTES ->
            refill(Pid, Stream),
            case decode(Data) of
                {ok, [<<"EVENT">>, Sub, E]} when is_map(E) ->
                    Valid =
                        try
                            lists:any(fun(F) -> erm_lens_nostr:matches(E, F) end, Filters)
                        catch
                            _:_ -> false
                        end,
                    Result =
                        case Valid of
                            true -> ingest(E, End);
                            false -> {error, wrong_filter}
                        end,
                    case Result of
                        ok -> collect(Pid, Stream, Sub, Filters, Left - 1, End, N + 1, Bad);
                        _ -> collect(Pid, Stream, Sub, Filters, Left - 1, End, N, Bad + 1)
                    end;
                {ok, [<<"EOSE">>, Sub]} ->
                    {N, Bad, eose};
                {ok, [<<"CLOSED">>, Sub, Reason]} ->
                    error({subscription_closed, safe_reason(Reason)});
                {error, DecodeReason} ->
                    ?LOG_DEBUG("ERM Lens relay ignored invalid JSON frame reason=~p", [DecodeReason]),
                    collect(Pid, Stream, Sub, Filters, Left - 1, End, N, Bad + 1);
                _ ->
                    collect(Pid, Stream, Sub, Filters, Left - 1, End, N, Bad)
            end;
        {gun_ws, Pid, Stream, {text, _}} ->
            error(oversized_relay_frame);
        {gun_ws, Pid, Stream, close} ->
            error(relay_closed);
        {gun_ws, Pid, Stream, {close, Code, Reason}} ->
            error({relay_closed, Code, Reason});
        {gun_ws, Pid, Stream, {close, Reason}} ->
            error({relay_closed, Reason});
        {gun_down, Pid, _Proto, Reason, _Killed, _Unprocessed} ->
            error({relay_down, Reason});
        {gun_down, Pid, _Proto, Reason, _Killed} ->
            error({relay_down, Reason});
        {gun_error, Pid, Stream, Reason} -> error({relay_error, safe_reason(Reason)});
        {gun_error, Pid, Reason} -> error({relay_error, safe_reason(Reason)});
        {'DOWN', _Mon, process, Pid, Reason} -> error({relay_down, safe_reason(Reason)});
        {gun_ws, Pid, Stream, {binary, _}} -> error(unexpected_binary_frame);
        {gun_ws, Pid, Stream, _Control} ->
            refill(Pid, Stream),
            collect(Pid, Stream, Sub, Filters, Left - 1, End, N, Bad)
    after remaining(End) ->
        error({relay_query_timeout, N, Bad})
    end.

await_ok(Pid, Stream, Id, End) ->
    await_ok(Pid, Stream, Id, End, 128).

await_ok(_Pid, _Stream, _Id, _End, 0) -> {error, acknowledgment_frame_limit};
await_ok(Pid, Stream, Id, End, Left) ->
    case remaining(End) of
        0 -> {error, acknowledgment_timeout};
        _ -> await_ok_message(Pid, Stream, Id, End, Left)
    end.

await_ok_message(Pid, Stream, Id, End, Left) ->
    receive
        {gun_ws, Pid, Stream, {text, Data}} when byte_size(Data) =< ?MAX_FRAME_BYTES ->
            refill(Pid, Stream),
            case decode(Data) of
                {ok, [<<"OK">>, Id, true, Message]} when is_binary(Message) ->
                    {ok, erm_lens_diagnostics:summary(Message)};
                {ok, [<<"OK">>, Id, false, Message]} when is_binary(Message) ->
                    {error, {rejected, erm_lens_diagnostics:summary(Message)}};
                _ -> await_ok(Pid, Stream, Id, End, Left - 1)
            end;
        {gun_ws, Pid, Stream, {text, _}} -> {error, oversized_relay_frame};
        {gun_ws, Pid, Stream, {binary, _}} -> {error, unexpected_binary_frame};
        {gun_ws, Pid, Stream, close} -> {error, relay_closed};
        {gun_ws, Pid, Stream, {close, Code, _}} -> {error, {relay_closed, Code}};
        {gun_ws, Pid, Stream, {close, _}} -> {error, relay_closed};
        {gun_down, Pid, _, Reason, _, _} -> {error, {relay_down, safe_reason(Reason)}};
        {gun_down, Pid, _, Reason, _} -> {error, {relay_down, safe_reason(Reason)}};
        {gun_error, Pid, Stream, Reason} -> {error, {relay_error, safe_reason(Reason)}};
        {gun_error, Pid, Reason} -> {error, {relay_error, safe_reason(Reason)}};
        {'DOWN', _Mon, process, Pid, Reason} -> {error, {relay_down, safe_reason(Reason)}};
        {gun_ws, Pid, Stream, _Control} ->
            refill(Pid, Stream),
            await_ok(Pid, Stream, Id, End, Left - 1)
    after remaining(End) -> {error, acknowledgment_timeout}
    end.

send_frame(Pid, Stream, Value) ->
    case encode(Value) of
        {ok, Payload} when byte_size(Payload) =< ?MAX_FRAME_BYTES ->
            %% Retain the uploaded Gun API; do not switch to ws_upgrade/4.
            try gun:ws_send(Pid, Stream, {text, Payload}) of
                ok -> ok;
                {error, Reason} -> {error, {ws_send_failed, safe_reason(Reason)}};
                _ -> {error, unexpected_ws_send_result}
            catch
                error:undef:Stack -> erlang:raise(error, undef, Stack);
                Class:Reason -> {error, {ws_send_failed, Class, safe_reason(Reason)}}
            end;
        {ok, _} -> {error, outbound_frame_too_large};
        {error, _} = Error -> Error
    end.

require_send(ok) -> ok;
require_send({error, Reason}) -> error({send_failed, Reason}).
encode(Value) -> erm_lens_codec:encode(Value).
decode(Data) -> erm_lens_codec:decode(Data).

safe_close(Pid) ->
    try gun:close(Pid) catch _:_ -> ok end,
    ok.

ingest(Event, End) ->
    Timeout = max(1, min(1000, remaining(End))),
    try gen_server:call(erm_lens_feed, {ingest, Event}, Timeout)
    catch
        exit:{timeout, _} -> error({feed_unavailable, timeout});
        exit:_ -> error({feed_unavailable, unavailable})
    end.

websocket_options() ->
    _ = code:ensure_loaded(gun),
    case erlang:function_exported(gun, update_flow, 3) of
        true -> #{compress => false, flow => 1};
        false -> #{compress => false}
    end.

refill(Pid, Stream) ->
    %% Gun 2.x supports flow control. Older/forked APIs retain existing behavior.
    %% This limits delivery, NOT Gun's allocation of a single huge/fragmented frame.
    case erlang:function_exported(gun, update_flow, 3) of
        true -> gun:update_flow(Pid, Stream, 1);
        false -> ok
    end.

safe_reason(R) when is_atom(R); is_integer(R) -> R;
safe_reason({relay_query_timeout, N, Bad}) -> {relay_query_timeout, N, Bad};
safe_reason({Tag, Reason}) when is_atom(Tag) -> {Tag, reason_tag(Reason)};
safe_reason(_) -> relay_operation_failed.
reason_tag(R) when is_atom(R); is_integer(R) -> R;
reason_tag({Tag, _}) when is_atom(Tag) -> Tag;
reason_tag(_) -> details_redacted.

undef_mfa([{M, F, A, _} | _]) when is_atom(M), is_atom(F), is_list(A) -> {M, F, length(A)};
undef_mfa([{M, F, Arity, _} | _]) when is_atom(M), is_atom(F), is_integer(Arity) -> {M, F, Arity};
undef_mfa(_) -> unknown.

stack_head(Stack) -> erm_lens_diagnostics:stack(Stack).

deadline(Ms) -> erlang:monotonic_time(millisecond) + Ms.
remaining(End) -> max(0, End - erlang:monotonic_time(millisecond)).
