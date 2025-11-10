-module(wikipedia_loader).
-behaviour(gen_server).
-behaviour(poolboy_worker).
-include_lib("kernel/include/logger.hrl").

-export([
    set_file/2,
    set_rate/1,
    pause/0,
    resume/0,
    break/0
]).
-export([
    start_link/1,
    init/1,
    handle_info/2,
    handle_call/3,
    handle_cast/2,
    terminate/2,
    code_change/3
]).

-record(state, {
    io_device,
    decoder_fun = undefined,
    rate_limit = 0,
    paused = false
}).

%%% API %%%

start_link([]) -> gen_server:start_link(?MODULE, [], []).

set_file(FilePath, RateLimit) ->
    gen_server:cast(
        gproc:lookup_local_name({?MODULE, ecai_wikipedia_loader}), {set_file, FilePath, RateLimit}
    ).
set_rate(RateLimit) ->
    gen_server:cast(
        gproc:lookup_local_name({?MODULE, ecai_wikipedia_loader}), {set_rate, RateLimit}
    ).
pause() ->
    gen_server:cast(gproc:lookup_local_name({?MODULE, ecai_wikipedia_loader}), pause).
resume() ->
    gen_server:cast(gproc:lookup_local_name({?MODULE, ecai_wikipedia_loader}), resume).
break() ->
    gen_server:cast(gproc:lookup_local_name({?MODULE, ecai_wikipedia_loader}), break).

%%% Init %%%
init(_Args) ->
    gproc:reg_other({n, l, {?MODULE, ecai_wikipedia_loader}}, self()),
    {ok, #state{}}.

%%% Tick Handler %%%
handle_call(Request, From, State) ->
    ?LOG_INFO("wikipedia loader call: ~p ~p~n", [Request, From]),
    {reply, ok, State}.

handle_info(tick, S = #state{paused = true}) ->
    schedule_next(S#state.rate_limit),
    {noreply, S};
handle_info(tick, S0 = #state{io_device = IO, decoder_fun = Dec}) when IO =/= undefined ->
    case file:read(IO, 64 * 1024) of
        {ok, Bin} ->
            ?LOG_DEBUG("decode ~p", [Bin]),
            %% feed to jsx decoder
            Dec(Bin),
            schedule_next(S0#state.rate_limit),
            {noreply, S0};
        eof ->
            %% signal EOF to jsx
            Dec(end_stream),
            _ = file:close(IO),
            ?LOG_INFO("JSON stream complete."),
            {stop, normal, S0};
        {error, Reason} ->
            ?LOG_ERROR("read error ~p", [Reason]),
            schedule_next(S0#state.rate_limit),
            {noreply, S0}
    end;
handle_info({json_object, Json}, S) ->
    handle_json(Json),
    {noreply, S}.

handle_cast({set_rate, Rate}, S) ->
    maybe_cancel_timer(),
    schedule_next(Rate),
    {noreply, S#state{rate_limit = Rate}};
handle_cast({set_file, FilePath, Rate}, S) ->
    case S#state.io_device of
        undefined -> ok;
        IO -> file:close(IO)
    end,
    {ok, IO2} = file:open(FilePath, [read, raw, binary]),
    %% Create a streaming decoder with our callback module
    Dec = jsx:decoder(ecai_wiki_json_cb, self(), [stream, return_maps, comments]),
    schedule_next(Rate),
    {noreply, S#state{io_device = IO2, decoder_fun = Dec, rate_limit = Rate, paused = false}};
handle_cast(pause, State) ->
    {noreply, State#state{paused = true}};
handle_cast(resume, State) ->
    {noreply, State#state{paused = false}};
handle_cast(break, State = #state{io_device = IO}) ->
    file:close(IO),
    {stop, normal, State}.

handle_json(Json) ->
    Ctx = ecai_search_server:get_ctx(),
    ok = index_wikipedia(Ctx, Json).

schedule_next(Rate) ->
    Ref = erlang:send_after(Rate, self(), tick),
    put(timer_ref, Ref),
    ok.

maybe_cancel_timer() ->
    case erase(timer_ref) of
        undefined ->
            ok;
        Ref ->
            erlang:cancel_timer(Ref),
            ok
    end.
terminate(_Reason, #state{io_device = IO}) ->
    file:close(IO),
    ok;
terminate(Reason, _) ->
    ?LOG_ERROR("wikipedia_loader Terminating ~p", [Reason]),
    ok.

code_change(_, State, _) -> {ok, State}.
%% ---------- Public: index one Wikipedia JSON object into ECAI search ----------
%% Usage from your JSON handler: ok = index_wikipedia(ecai_search_server:get_ctx(), JsonMap).
index_wikipedia(Ctx, Json) when is_map(Json) ->
    {DocId, Rec} = wiki_to_search_record(Json),
    ok = ecai_search:upsert_record(Ctx, DocId, Rec),
    %% Also index the abstract text into a dedicated field for retrieval
    Abstract = maps:get(<<"abstract">>, Json, <<>>),
    ecai_search:index_text(Ctx, DocId, <<"abstract">>, Abstract, 120),
    ok.

%% ---------- Convert raw Wikipedia record -> {DocIdBin, DataMap} for ecai_search ----------
wiki_to_search_record(J) ->
    Name = b(maps:get(<<"name">>, J, <<>>)),
    %% canonical article URL
    Url = b(maps:get(<<"url">>, J, <<>>)),
    LangId = get_in(J, [<<"in_language">>, <<"identifier">>], <<"en">>),
    Abs = b(maps:get(<<"abstract">>, J, <<>>)),
    PageId =
        case maps:get(<<"identifier">>, J, undefined) of
            I when is_integer(I) -> list_to_binary(integer_to_list(I));
            I when is_binary(I) -> I;
            %% fallback: URL hash
            _ -> crypto:hash(sha256, Url)
        end,
    %% Optional niceties
    Image = get_in(J, [<<"image">>, <<"content_url">>], <<>>),
    WikiData = get_in(J, [<<"main_entity">>, <<"identifier">>], <<>>),

    %% We’ll store a compact map tuned for ecai_search: name/category/tags etc.
    %% Important: keep a direct link back to Wikipedia under <<"link">>.
    Data = #{
        %% Core fields ecai_search already weights nicely
        name => Name,
        category => <<"wikipedia">>,
        %% unused but present in schema
        city => <<>>,
        tags => wiki_tags(LangId, WikiData),
        %% n/a
        phone => <<>>,
        %% Rich metadata you’ll want in UI / previews / downstream apps

        %% <— link to original page
        link => Url,
        %% (duplicate for convenience)
        url => Url,
        abstract => Abs,
        language => LangId,
        image => Image,
        wikidata_id => WikiData,
        date_modified => b(maps:get(<<"date_modified">>, J, <<>>)),
        license => wiki_license_list(J)
    },
    %% DocId: prefer stable page identifier; fall back to URL
    {PageId, Data}.

%% ---------- Helpers ----------
%% was: b(B) when is_binary(B) -> B.
b(B) when is_binary(B) -> binary:copy(B);
b(L) when is_list(L) -> list_to_binary(L);
b(Other) -> iolist_to_binary(io_lib:format("~p", [Other])).

get_in(Map, [K | Ks], Default) when is_map(Map) ->
    case maps:get(K, Map, '$nope') of
        '$nope' -> Default;
        V when Ks =:= [] -> V;
        V -> get_in(V, Ks, Default)
    end;
get_in(_, _, Default) ->
    Default.

wiki_tags(LangId, WikiDataId) ->
    Base = [<<"wiki">>, LangId],
    case WikiDataId of
        <<>> -> Base;
        WD -> [damage_utils:binarystr_join([<<"wikidata:">>, b(WD)]) | Base]
    end.

wiki_license_list(J) ->
    case maps:get(<<"license">>, J, []) of
        L when is_list(L) ->
            [
                #{
                    id => maps:get(<<"identifier">>, X, <<>>),
                    name => maps:get(<<"name">>, X, <<>>),
                    url => maps:get(<<"url">>, X, <<>>)
                }
             || X <- L, is_map(X)
            ];
        _ ->
            []
    end.
