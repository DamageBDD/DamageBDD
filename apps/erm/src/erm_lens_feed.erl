%%% Verified, bounded event store. Remote terms must never crash the feed.
-module(erm_lens_feed).
-behaviour(gen_server).
-export([start_link/1, ingest/1, snapshot/1, ids/0, mute/1, follow/1, status/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

start_link(C) -> gen_server:start_link({local, ?MODULE}, ?MODULE, C, []).
ingest(E) -> gen_server:call(?MODULE, {ingest, E}, 10000).
snapshot(Mode) -> gen_server:call(?MODULE, {snapshot, Mode}, 10000).
ids() -> gen_server:call(?MODULE, ids).
mute(P) -> gen_server:call(?MODULE, {mute, P}).
follow(P) -> gen_server:call(?MODULE, {follow, P}).
status() -> gen_server:call(?MODULE, status).

init(C) ->
    process_flag(trap_exit, true),
    Timer = erlang:start_timer(30000, self(), prune),
    {ok, #{
        model => erm_lens_model:new(C),
        rejected => 0,
        revision => 0,
        epoch => make_ref(),
        timer => Timer,
        last_rejection => undefined
    }}.

handle_call({ingest, E}, _, S) ->
    case erm_lens_nostr:verify(E) of
        ok ->
            M = erm_lens_model:insert(E, erlang:system_time(second), maps:get(model, S)),
            {reply, ok, changed(M, S)};
        Error ->
            {reply, Error, S#{rejected := maps:get(rejected, S) + 1, last_rejection := Error}}
    end;
handle_call({snapshot, Mode}, _, S) when Mode =:= popular; Mode =:= newest; Mode =:= following ->
    S1 = prune(S),
    {reply, erm_lens_model:rank(maps:get(model, S1), Mode, erlang:system_time(second)), S1};
handle_call({snapshot, _}, _, S) ->
    {reply, {error, invalid_feed_mode}, S};
handle_call(ids, _, S) ->
    S1 = prune(S),
    {reply, lists:sublist(erm_lens_model:ids(maps:get(model, S1)), 200), S1};
handle_call({mute, P}, _, S) ->
    preference(mute, muted, P, S);
handle_call({follow, P}, _, S) ->
    preference(follow, following, P, S);
handle_call(status, _, S) ->
    M = maps:get(model, S),
    {reply,
        #{
            events => erm_lens_model:size(M),
            bytes => maps:get(bytes, M, 0),
            max_store_bytes => maps:get(byte_limit, M, 67108864),
            rejected => maps:get(rejected, S),
            revision => maps:get(revision, S),
            epoch => maps:get(epoch, S),
            last_rejection => maps:get(last_rejection, S)
        },
        S};
handle_call(_, _, S) ->
    {reply, {error, unsupported_call}, S}.

handle_cast(_, S) -> {noreply, S}.
handle_info({timeout, Ref, prune}, S = #{timer := Ref}) ->
    Timer = erlang:start_timer(30000, self(), prune),
    {noreply, prune(S#{timer := Timer})};
handle_info(_, S) ->
    {noreply, S}.
terminate(_, S) ->
    erlang:cancel_timer(maps:get(timer, S)),
    ok.
code_change(_, S, _) ->
    Timer =
        case maps:get(timer, S, undefined) of
            Ref when is_reference(Ref) -> Ref;
            _ -> erlang:start_timer(30000, self(), prune)
        end,
    {ok, S#{epoch => maps:get(epoch, S, make_ref()), timer => Timer}}.

preference(Fun, Key, P, S) ->
    M = maps:get(model, S),
    Prefs = maps:get(Key, M),
    case {erm_lens_nostr:is_hex(P, 64), maps:is_key(P, Prefs), map_size(Prefs) < 4096} of
        {false, _, _} -> {reply, {error, invalid_pubkey}, S};
        {true, false, false} -> {reply, {error, preference_limit}, S};
        _ -> {reply, ok, changed(apply(erm_lens_model, Fun, [P, M]), S)}
    end.

prune(S) -> changed(erm_lens_model:prune(erlang:system_time(second), maps:get(model, S)), S).
changed(M, S) ->
    case M =:= maps:get(model, S) of
        true -> S;
        false -> S#{model := M, revision := maps:get(revision, S) + 1}
    end.
