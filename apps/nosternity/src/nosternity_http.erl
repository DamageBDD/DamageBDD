%%--------------------------------------------------------------------
%% nosternity_http.erl
%%
%% Minimal Nostr “note thread” HTTP surface:
%%   - GET /nostr/note/?id=<event_id>              -> simple HTML UI (minimal JS)
%%   - GET /api/nostr/note/?id=<event_id>&limit=.. -> JSON: note + reactions + comments
%%
%% Notes:
%% - Uses damage_nostr:fetch_event_by_id/2 for the root note (already in your code).
%% - Uses nostr_pool:req/3 (if present) to fetch reactions/comments by filters.
%%   (Erlang won’t fail compile if nostr_pool:req/3 doesn’t exist; it will fail at runtime.)
%%--------------------------------------------------------------------

-module(nosternity_http).

-vsn("0.1.0").

-author("Steven Joseph <steven@stevenjoseph.in>").
-copyright("Steven Joseph <steven@stevenjoseph.in>").
-license("Apache-2.0").

-export([init/2]).
-export([content_types_provided/2]).
-export([allowed_methods/2]).
-export([to_html/2]).
-export([to_json/2]).
-export([trails/0]).

-include_lib("kernel/include/logger.hrl").

-define(DEFAULT_TIMEOUT, 60000).
-define(TRAILS_TAG, ["Nostr Views"]).
-define(DEFAULT_FANOUT, 3).
-define(DEFAULT_LIMIT, 200).

%% --- Trails (static paths only; pass note id via query string)

trails() ->
    [
        trails:trail(
            "/nostr/note/",
            nosternity_http,
            #{action => note_ui},
            #{
                get =>
                    #{
                        tags => ?TRAILS_TAG,
                        description =>
                            "Minimal Nostr note viewer UI (note + reactions + comments).",
                        produces => ["text/html"]
                    }
            }
        ),
        trails:trail(
            "/api/nostr/note/",
            nosternity_http,
            #{action => note_json},
            #{
                get =>
                    #{
                        tags => ?TRAILS_TAG,
                        description => "Fetch a Nostr note thread (note + reactions + comments).",
                        produces => ["application/json"],
                        parameters =>
                            [
                                #{
                                    name => <<"id">>,
                                    description => <<"Nostr event id (hex).">>,
                                    in => <<"query">>,
                                    required => true,
                                    type => <<"string">>
                                },
                                #{
                                    name => <<"limit">>,
                                    description => <<"Max comments/reactions to return.">>,
                                    in => <<"query">>,
                                    required => false,
                                    type => <<"integer">>
                                }
                            ]
                    }
            }
        )
    ].

init(Req, Opts) -> {cowboy_rest, Req, Opts}.

content_types_provided(Req, State) ->
    {
        [
            {{<<"application">>, <<"json">>, []}, to_json},
            {{<<"text">>, <<"html">>, '*'}, to_html}
        ],
        Req,
        State
    }.

allowed_methods(Req, State) ->
    {[<<"GET">>], Req, State}.

%%--------------------------------------------------------------------
%% JSON endpoint
%%--------------------------------------------------------------------

to_json(Req0, #{action := note_json} = State) ->
    Qs = cowboy_req:parse_qs(Req0),
    Id = qs_get_bin(<<"id">>, Qs, <<>>),
    Limit = qs_get_int(<<"limit">>, Qs, ?DEFAULT_LIMIT),

    case Id of
        <<>> ->
            Body = jsx:encode(#{status => <<"error">>, message => <<"missing_query_id">>}),
            Req1 = cowboy_req:reply(
                400, #{<<"content-type">> => <<"application/json">>}, Body, Req0
            ),
            {stop, Req1, State};
        _ ->
            case get_note_thread(Id, Limit) of
                {ok, Thread} ->
                    Body = jsx:encode(maps:put(status, <<"ok">>, Thread)),
                    Req1 = cowboy_req:reply(
                        200,
                        #{<<"content-type">> => <<"application/json">>},
                        Body,
                        Req0
                    ),
                    {stop, Req1, State};
                {error, Reason} ->
                    Body = jsx:encode(#{status => <<"error">>, message => to_bin(Reason)}),
                    Req1 = cowboy_req:reply(
                        502,
                        #{<<"content-type">> => <<"application/json">>},
                        Body,
                        Req0
                    ),
                    {stop, Req1, State}
            end
    end;
to_json(Req, State) ->
    Req1 = cowboy_req:reply(404, #{<<"content-type">> => <<"application/json">>}, <<"{}">>, Req),
    {stop, Req1, State}.

%%--------------------------------------------------------------------
%% HTML UI endpoint (minimal JS)
%%--------------------------------------------------------------------

%% damage_nostr_http.erl (replace to_html/2 for note_ui)
to_html(Req0, #{action := note_ui} = State) ->
    Qs = cowboy_req:parse_qs(Req0),
    Id0 = qs_get_bin(<<"id">>, Qs, <<>>),
    Id = html_escape(Id0),

    %% Render inner page (nostr_note.mustache)
    BodyInner =
        damage_utils:load_template(
            damage,
            "nostr_note.mustache",
            #{
                event_id => Id,
                limit => ?DEFAULT_LIMIT
            }
        ),

    %% Wrap with shell (page_shell.mustache)
    Html =
        damage_utils:load_template(
            damage,
            "page_shell.mustache",
            #{
                title => <<"Nostr Note">>,
                body => BodyInner,
                head_extra => <<>>,
                tail_extra => <<>>
            }
        ),

    {Html, Req0, State}.

%%--------------------------------------------------------------------
%% Core logic
%%--------------------------------------------------------------------

get_note_thread(EventId0, Limit0) ->
    EventId = to_bin(EventId0),
    Limit =
        case Limit0 of
            I when is_integer(I), I > 0 -> I;
            _ -> ?DEFAULT_LIMIT
        end,

    %% 1) Root note
    NoteRes = damage_nostr:fetch_event_by_id(damage_nostr_nsec, EventId),
    case NoteRes of
        {ok, Note} when is_map(Note) ->
            %% 2) Reactions (kind 7) and Comments (kind 1 that reference root via #e)
            Reactions = fetch_by_filter(#{
                <<"kinds">> => [7],
                <<"#e">> => [EventId],
                <<"limit">> => Limit
            }),
            Comments = fetch_by_filter(#{
                <<"kinds">> => [1],
                <<"#e">> => [EventId],
                <<"limit">> => Limit
            }),

            {ok, #{
                note => Note,
                reactions => sanitize_events(Reactions),
                comments => sanitize_events(Comments)
            }};
        {error, _} = Err ->
            Err;
        Other ->
            {error, {bad_note_lookup, Other}}
    end.

fetch_by_filter(Filter) ->
    %% Prefer nostr_pool:req(Filter, Timeout, Fanout) -> {ok, [Events]}
    %% If your pool only has req_one/3, you can swap this implementation easily.
    try
        case nostr_pool:req(Filter, ?DEFAULT_TIMEOUT, ?DEFAULT_FANOUT) of
            {ok, Events} when is_list(Events) -> Events;
            {ok, Event} when is_map(Event) -> [Event];
            {error, _} ->
                [];
            Other ->
                ?LOG_DEBUG("nostr_pool:req unexpected ~p", [Other]),
                []
        end
    catch
        C:R ->
            ?LOG_WARNING("fetch_by_filter failed ~p:~p filter=~p", [C, R, Filter]),
            []
    end.

sanitize_events(Events) when is_list(Events) ->
    %% Keep only maps, and keep only keys that are useful for UI.
    [pick_event_fields(E) || E <- Events, is_map(E)];
sanitize_events(_) ->
    [].

pick_event_fields(E) ->
    #{
        <<"id">> => maps:get(<<"id">>, E, maps:get(id, E, <<>>)),
        <<"pubkey">> => maps:get(<<"pubkey">>, E, maps:get(pubkey, E, <<>>)),
        <<"created_at">> => maps:get(<<"created_at">>, E, maps:get(created_at, E, 0)),
        <<"kind">> => maps:get(<<"kind">>, E, maps:get(kind, E, -1)),
        <<"content">> => maps:get(<<"content">>, E, maps:get(content, E, <<>>)),
        <<"tags">> => maps:get(<<"tags">>, E, maps:get(tags, E, []))
    }.

%%--------------------------------------------------------------------
%% Small helpers
%%--------------------------------------------------------------------

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> list_to_binary(L);
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_bin(I) when is_integer(I) -> integer_to_binary(I);
to_bin(T) -> iolist_to_binary(io_lib:format("~p", [T])).

qs_get_bin(Key, Qs, Default) ->
    case lists:keyfind(Key, 1, Qs) of
        {_, V} when is_binary(V) -> V;
        {_, V} when is_list(V) -> list_to_binary(V);
        false -> Default
    end.

qs_get_int(Key, Qs, Default) ->
    case lists:keyfind(Key, 1, Qs) of
        {_, V} when is_integer(V) -> V;
        {_, V} when is_binary(V) ->
            case catch binary_to_integer(V) of
                I when is_integer(I) -> I;
                _ -> Default
            end;
        {_, V} when is_list(V) ->
            case catch list_to_integer(V) of
                I when is_integer(I) -> I;
                _ -> Default
            end;
        false ->
            Default
    end.

html_escape(<<>>) ->
    <<>>;
html_escape(Bin0) ->
    Bin = to_bin(Bin0),
    %% minimal escaping for value=""
    Bin1 = binary:replace(Bin, <<"&">>, <<"&amp;">>, [global]),
    Bin2 = binary:replace(Bin1, <<"<">>, <<"&lt;">>, [global]),
    Bin3 = binary:replace(Bin2, <<">">>, <<"&gt;">>, [global]),
    binary:replace(Bin3, <<"\"">>, <<"&quot;">>, [global]).
