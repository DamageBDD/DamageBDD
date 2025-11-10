%% =====================================================================
%% wikipedia_loader.erl  --  Minimal Wikipedia JSONL loader
%% =====================================================================
-module(wikipedia_loader).
-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").
-export([load/1]).

-include_lib("kernel/include/logger.hrl").

load(FilePath) ->
    case file:open(FilePath, [read]) of
        {ok, IoDevice} ->
            read_lines(IoDevice);
        {error, Reason} ->
            io:format("Error opening file: ~p~n", [Reason]),
            {error, Reason}
    end.

read_lines(IoDevice) ->
    case io:get_line(IoDevice, '') of
        eof ->
            file:close(IoDevice);
        {error, Reason} ->
            file:close(IoDevice),
            ?LOG_ERROR("Error reading line: ~p~n", [Reason]),
            {error, Reason};
        Line ->
            case jsx:decode(list_to_binary(Line)) of
                {error, Reason} ->
                    ?LOG_ERROR("Error decoding JSON: ~p in line: ~s~n", [Reason, Line]),
                    % Optionally skip invalid lines
                    read_lines(IoDevice);
                DecodedJson ->
                    ok = default_index(DecodedJson),
                    read_lines(IoDevice)
            end
    end.

%% ---- default indexer (keeps a link back to Wikipedia) ----------------

default_index(Json) when is_map(Json) ->
    Ctx = ecai_search_server:get_ctx(),
    {DocId, Rec} = wiki_to_search_record(Json),
    ok = ecai_search:upsert_record(Ctx, DocId, Rec),
    %% also index abstract text for retrieval weight
    Abstract = maps:get(<<"abstract">>, Json, <<>>),
    ecai_search:index_text(Ctx, DocId, <<"abstract">>, Abstract, 120),
    ok.

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
            _ -> crypto:hash(sha256, Url)
        end,
    Image = get_in(J, [<<"image">>, <<"content_url">>], <<>>),
    WikiData = get_in(J, [<<"main_entity">>, <<"identifier">>], <<>>),
    Data = #{
        name => Name,
        category => <<"wikipedia">>,
        tags => wiki_tags(LangId, WikiData),
        %% direct link back to Wikipedia
        link => Url,
        url => Url,
        abstract => Abs,
        language => LangId,
        image => Image,
        wikidata_id => WikiData,
        date_modified => b(maps:get(<<"date_modified">>, J, <<>>)),
        license => wiki_license_list(J)
    },
    {PageId, Data}.

%% ---- small helpers ---------------------------------------------------

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

wiki_tags(LangId, WD) ->
    Base = [<<"wiki">>, LangId],
    case WD of
        <<>> -> Base;
        _ -> [damage_utils:binarystr_join([<<"wikidata:">>, b(WD)]) | Base]
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
