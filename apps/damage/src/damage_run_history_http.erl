%%% Public run-history directory and read-only AEMDW activity facade.
%%% Never disclose key material or proxy arbitrary remote URLs.
%%% Global discovery is a bounded *recent* middleware index; the deployed
%%% NodeRegistry v2 has no global enumerable entrypoint. Owner lookup is complete
%%% for that owner, and node lookup is authoritative for that node id.
-module(damage_run_history_http).

-author("Steven Joseph <steven@damagebdd.com>").
-license("Apache-2.0").

-export([trails/0, init/2, allowed_methods/2, content_types_provided/2, to_json/2]).
-export([decode_node_ids/1, registered_node/2, registry_account/1, validate_activity_path/1]).

-include_lib("kernel/include/logger.hrl").

-define(MAX_DISCOVERED, 16).
-define(MAX_OWNER_NODES, 64).
-define(MDW_LIMIT, 75).
-define(MDW_TIMEOUT, 6500).

trails() ->
    [
        trails:trail(
            "/api/run-history/nodes",
            ?MODULE,
            #{action => nodes},
            #{
                get => #{
                    tags => ["Run history"],
                    description =>
                        "Read public nodes from NodeRegistry by owner/node, or discover recent registrations.",
                    produces => ["application/json"]
                }
            }
        ),
        trails:trail(
            "/api/run-history/activities",
            ?MODULE,
            #{action => activities},
            #{
                get => #{
                    tags => ["Run history"],
                    description =>
                        "Read public AEMDW verification transactions via a restricted same-origin endpoint.",
                    produces => ["application/json"]
                }
            }
        )
    ].

init(Req, Opts) -> {cowboy_rest, Req, Opts}.
allowed_methods(Req, State) -> {[<<"GET">>], Req, State}.
content_types_provided(Req, State) ->
    {[{{<<"application">>, <<"json">>, '*'}, to_json}], Req, State}.

to_json(Req0, #{action := activities} = State) ->
    Req = cowboy_req:set_resp_header(<<"cache-control">>, <<"public, max-age=10">>, Req0),
    Params = maps:from_list(cowboy_req:parse_qs(Req)),
    Response =
        case throttle:check(damage_api_rate, damage_utils:get_ip(Req)) of
            {limit_exceeded, _, _} ->
                {429, #{status => <<"error">>, error => <<"rate limited">>}};
            _ ->
                case validate_activity_path(maps:get(<<"path">>, Params, <<>>)) of
                    {ok, Path} ->
                        read_public_activities(Path);
                    {error, _} ->
                        {400, #{status => <<"error">>, error => <<"invalid public activity path">>}}
                end
        end,
    reply_public_json(Req, State, Response);
to_json(Req0, #{action := nodes} = State) ->
    Req = cowboy_req:set_resp_header(<<"cache-control">>, <<"public, max-age=30">>, Req0),
    Params = maps:from_list(cowboy_req:parse_qs(Req)),
    Result =
        case
            {
                maps:get(<<"node">>, Params, <<>>),
                maps:get(<<"owner">>, Params, <<>>),
                maps:get(<<"discover">>, Params, <<>>)
            }
        of
            {NodeId, _, _} when NodeId =/= <<>> ->
                lookup_node(NodeId);
            {<<>>, Owner, _} when Owner =/= <<>> ->
                lookup_owner(Owner);
            {<<>>, <<>>, <<"1">>} ->
                discover_nodes();
            _ ->
                {400, #{status => <<"error">>, error => <<"node, owner or discover=1 required">>}}
        end,
    reply_public_json(Req, State, Result).

reply_public_json(Req, State, {Status, Body}) ->
    Req1 = cowboy_req:set_resp_header(<<"x-content-type-options">>, <<"nosniff">>, Req),
    {stop,
        cowboy_req:reply(
            Status,
            #{<<"content-type">> => <<"application/json; charset=utf-8">>},
            jsx:encode(Body),
            Req1
        ),
        State}.

%% Only AEMDW v3 contract calls, transaction and account-activity reads are exposed. Accept
%% middleware pagination paths (/mdw/v3/...) but never origins, arbitrary
%% routes, traversal, user-provided hosts or unbounded queries.
-spec validate_activity_path(binary() | list()) -> {ok, binary()} | {error, invalid_path}.
validate_activity_path(Path0) when is_list(Path0) ->
    validate_activity_path(unicode:characters_to_binary(Path0));
validate_activity_path(Path0) when
    is_binary(Path0),
    byte_size(Path0) > 0,
    byte_size(Path0) =< 1800
->
    try
        Parsed = uri_string:parse(Path0),
        %% url parse must contain *only* a path and optional query.
        false = maps:is_key(scheme, Parsed),
        false = maps:is_key(host, Parsed),
        false = maps:is_key(fragment, Parsed),
        RawPath = bin(maps:get(path, Parsed)),
        Path =
            case RawPath of
                <<"/mdw/v3/", Rest/binary>> -> <<"/v3/", Rest/binary>>;
                _ -> RawPath
            end,
        true = public_activity_route(Path),
        Query0 = maps:get(query, Parsed, <<>>),
        Query = bin(Query0),
        true = byte_size(Query) =< 1400,
        Parameters =
            case Query of
                <<>> ->
                    [];
                _ ->
                    [
                        {binary_to_list(bin(K)), binary_to_list(bin(V))}
                     || {K, V} <- uri_string:dissect_query(Query)
                    ]
            end,
        true = length(Parameters) =< 12,
        true = lists:all(fun valid_activity_param/1, Parameters),
        QueryOut =
            case Parameters of
                [] -> <<>>;
                _ -> <<"?", (bin(uri_string:compose_query(Parameters)))/binary>>
            end,
        {ok, <<Path/binary, QueryOut/binary>>}
    catch
        _:_ -> {error, invalid_path}
    end;
validate_activity_path(_) ->
    {error, invalid_path}.

public_activity_route(Path) ->
    (re:run(
        Path,
        <<"^/v3/transactions(/th_[1-9A-HJ-NP-Za-km-z]{20,70})?/?$">>,
        [{capture, none}]
    ) =:= match) orelse
        (re:run(Path, <<"^/v3/contracts/calls/?$">>, [{capture, none}]) =:= match) orelse
        (re:run(
            Path,
            <<"^/v3/accounts/ak_[1-9A-HJ-NP-Za-km-z]{20,70}/activities/?$">>,
            [{capture, none}]
        ) =:= match).

valid_activity_param({"direction", "backward"}) ->
    true;
valid_activity_param({"type", T}) ->
    lists:member(T, ["contract_call", "paying_for", "transactions"]);
valid_activity_param({"owned_only", V}) ->
    lists:member(V, ["true", "false"]);
valid_activity_param({"contract_id", V}) ->
    registry_account(V) =/= error andalso
        lists:prefix("ct_", V);
valid_activity_param({"contract", V}) ->
    registry_account(V) =/= error andalso
        lists:prefix("ct_", V);
valid_activity_param({"limit", V}) ->
    try
        N = list_to_integer(V),
        N >= 1 andalso N =< 100
    catch
        _:_ -> false
    end;
valid_activity_param({K, V}) when K =:= "cursor"; K =:= "page" ->
    length(V) =< 512 andalso length(V) > 0 andalso
        re:run(V, "^[A-Za-z0-9_~=+:/.-]+$", [{capture, none}]) =:= match;
valid_activity_param(_) ->
    false.

read_public_activities(Path) ->
    Source =
        try
            damage_ae:get_ae_mdw_node()
        catch
            _:_ -> {error, middleware_unavailable}
        end,
    case Source of
        {ok, ConnPid, Prefix0} ->
            try
                Prefix = string:trim(binary_to_list(bin(Prefix0)), trailing, "/") ++ "/",
                RequestPath = Prefix ++ string:trim(binary_to_list(Path), leading, "/"),
                case gun:await_up(ConnPid, ?MDW_TIMEOUT) of
                    {ok, _Protocol} ->
                        Stream = gun:get(
                            ConnPid,
                            RequestPath,
                            [{<<"accept">>, <<"application/json">>}]
                        ),
                        case gun:await(ConnPid, Stream, ?MDW_TIMEOUT) of
                            {response, nofin, 200, _Headers} ->
                                case gun:await_body(ConnPid, Stream, ?MDW_TIMEOUT) of
                                    {ok, Body} when byte_size(Body) =< 3000000 ->
                                        try
                                            {200, jsx:decode(Body, [return_maps])}
                                        catch
                                            _:_ -> public_activity_unavailable()
                                        end;
                                    _ ->
                                        public_activity_unavailable()
                                end;
                            {response, fin, 200, _Headers} ->
                                {200, #{data => []}};
                            _ ->
                                public_activity_unavailable()
                        end;
                    _ ->
                        public_activity_unavailable()
                end
            catch
                Class:Reason ->
                    ?LOG_WARNING("Run history AEMDW activity request failed ~p:~p", [Class, Reason]),
                    public_activity_unavailable()
            after
                try
                    gun:close(ConnPid)
                catch
                    _:_ -> ok
                end
            end;
        _ ->
            public_activity_unavailable()
    end.

public_activity_unavailable() ->
    {502, #{status => <<"error">>, error => <<"public middleware unavailable">>}}.

lookup_node(Node) ->
    case registry_account(Node) of
        {ok, NodeId} ->
            case registered_node(NodeId, undefined) of
                {ok, Info} ->
                    {200, #{status => <<"ok">>, nodes => [Info]}};
                {error, not_registered} ->
                    {404, #{status => <<"error">>, error => <<"node not registered">>}};
                {error, _} ->
                    unavailable()
            end;
        error ->
            bad_address()
    end.

lookup_owner(Owner) ->
    case registry_account(Owner) of
        {ok, <<"ak_", _/binary>> = Id} ->
            case registry_call(fun() -> damage_node_registry:get_nodes_for(Id) end) of
                {ok, Reply} ->
                    case decode_node_ids(Reply) of
                        {ok, Ids} ->
                            Nodes = verified_nodes(lists:sublist(Ids, ?MAX_OWNER_NODES), Id),
                            {200, #{
                                status => <<"ok">>,
                                source => <<"node_registry_owner">>,
                                owner => Id,
                                nodes => Nodes,
                                total => length(Ids),
                                complete => length(Ids) =< ?MAX_OWNER_NODES
                            }};
                        {error, _} ->
                            unavailable()
                    end;
                {error, _} ->
                    unavailable()
            end;
        _ ->
            bad_address()
    end.

%% The contract is owner-scoped. Discover *recently registered* node ids from
%% public middleware transaction arguments, then verify each via get_node/1.
%% No unverified data is surfaced in the directory.
discover_nodes() ->
    case fetch_registry_transactions() of
        {ok, Transactions} ->
            Ids = lists:usort(lists:append([register_ids(Row) || Row <- Transactions])),
            Limited = lists:sublist(Ids, ?MAX_DISCOVERED),
            Nodes = verified_nodes(Limited, undefined),
            {200, #{
                status => <<"ok">>,
                source => <<"recent_registry_transactions">>,
                scanned => length(Transactions),
                nodes => Nodes,
                complete => false,
                note =>
                    <<"Recent contract transactions only. Search by owner to list that owner's registered nodes.">>
            }};
        {error, Reason} ->
            ?LOG_WARNING("Run history public registry discovery unavailable: ~p", [Reason]),
            {503, #{status => <<"error">>, error => <<"public registry discovery unavailable">>}}
    end.

verified_nodes(Ids, Owner) ->
    [Info || Id <- Ids, {ok, Info} <- [registered_node(Id, Owner)]].

registered_node(NodeId, ExpectedOwner) ->
    case registry_account(NodeId) of
        {ok, Id} ->
            case registry_call(fun() -> damage_node_registry:get_node(Id) end) of
                {ok, Reply} ->
                    case unwrap_registry_reply(Reply) of
                        {ok, Raw} ->
                            case normalize_node(Raw) of
                                {error, _} = Error ->
                                    Error;
                                Info0 ->
                                    Owner0 = maps:get(owner, Info0, <<>>),
                                    Owner =
                                        case Owner0 of
                                            <<>> -> lookup_node_owner(Id);
                                            _ -> Owner0
                                        end,
                                    case
                                        ExpectedOwner =:= undefined orelse Owner =:= ExpectedOwner
                                    of
                                        true ->
                                            {ok, Info0#{
                                                id => Id,
                                                owner => Owner,
                                                name => node_name(Id, Info0),
                                                registered => true
                                            }};
                                        false ->
                                            {error, owner_mismatch}
                                    end
                            end;
                        {error, _} ->
                            {error, not_registered}
                    end;
                {error, Reason} ->
                    {error, Reason}
            end;
        error ->
            {error, invalid_address}
    end.

lookup_node_owner(NodeId) ->
    case registry_call(fun() -> damage_node_registry:get_node_owner(NodeId) end) of
        {ok, Reply} ->
            case unwrap_registry_reply(Reply) of
                {ok, Address} -> address_value(Address);
                _ -> <<>>
            end;
        _ ->
            <<>>
    end.

node_name(Id, Info) ->
    case maps:get(name, Info, <<>>) of
        <<>> -> Id;
        Name -> Name
    end.

registry_account(Id0) when is_list(Id0) -> registry_account(unicode:characters_to_binary(Id0));
registry_account(Id) when is_binary(Id), byte_size(Id) =< 80 ->
    case re:run(Id, <<"^(ak|ct)_[1-9A-HJ-NP-Za-km-z]{20,70}$">>, [{capture, none}]) of
        match -> {ok, Id};
        nomatch -> error
    end;
registry_account(_) ->
    error.

registry_call(Fun) ->
    try Fun() of
        {error, Reason} -> {error, Reason};
        Reply -> {ok, Reply}
    catch
        Class:Reason ->
            ?LOG_WARNING("Run-history NodeRegistry lookup failed class=~p reason=~p", [
                Class, Reason
            ]),
            {error, registry_unavailable}
    end.

unwrap_registry_reply(#{"return_type" := "ok", "return_value" := Value}) ->
    {ok, Value};
unwrap_registry_reply(#{<<"return_type">> := <<"ok">>, <<"return_value">> := Value}) ->
    {ok, Value};
unwrap_registry_reply(_) ->
    {error, registry_rejected}.

decode_node_ids(Reply) ->
    case unwrap_registry_reply(Reply) of
        {ok, {list, Ids}} when is_list(Ids) -> node_ids(Ids);
        {ok, Ids} when is_list(Ids) -> node_ids(Ids);
        {ok, #{"nodes" := Ids}} when is_list(Ids) -> node_ids(Ids);
        _ -> {error, invalid_node_list}
    end.

node_ids(Ids) ->
    {ok, lists:usort([Id || Item <- Ids, Id <- [address_value(Item)], Id =/= <<>>])}.

address_value({address, Raw}) when is_binary(Raw), byte_size(Raw) =:= 32 ->
    try
        aeser_api_encoder:encode(account_pubkey, Raw)
    catch
        _:_ -> <<>>
    end;
address_value({address, Id}) ->
    address_value(Id);
address_value(#{"value" := Value}) ->
    address_value(Value);
address_value(#{<<"value">> := Value}) ->
    address_value(Value);
address_value(Id) when is_binary(Id) ->
    case registry_account(Id) of
        {ok, Address} -> Address;
        _ -> <<>>
    end;
address_value(Id) when is_list(Id) -> address_value(unicode:characters_to_binary(Id));
address_value(_) ->
    <<>>.

normalize_node(Map) when is_map(Map) ->
    Meta = value(meta, Map, #{}),
    Cfg = value(cfg, Map, #{}),
    #{
        owner => address_value(value(owner_account, Map, <<>>)),
        name => bin(value(name, Meta, <<>>)),
        endpoint => bin(value(endpoint, Meta, <<>>)),
        location => bin(value(location, Meta, <<>>)),
        version => bin(value(version, Meta, <<>>)),
        enabled => boolean(value(enabled, Cfg, true))
    };
normalize_node({record, Values}) ->
    normalize_node(Values);
normalize_node([Owner, _RegisteredAt, Meta, Cfg | _]) ->
    normalize_node(#{owner_account => Owner, meta => record_meta(Meta), cfg => record_cfg(Cfg)});
normalize_node(_) ->
    %% A successful call is not by itself proof that an unknown variant is a
    %% registered node; reject unexpected Sophia return shapes.
    {error, invalid_node_record}.

record_meta({record, Values}) ->
    record_meta(Values);
record_meta([Name, Endpoint, Location, Version, _Notes | _]) ->
    #{
        name => untype(Name),
        endpoint => untype(Endpoint),
        location => untype(Location),
        version => untype(Version)
    };
record_meta(M) when is_map(M) -> M;
record_meta(_) ->
    #{}.

record_cfg({record, Values}) -> record_cfg(Values);
record_cfg([Enabled | _]) -> #{enabled => untype(Enabled)};
record_cfg(M) when is_map(M) -> M;
record_cfg(_) -> #{}.

untype({_, Value}) -> Value;
untype(Value) -> Value.

value(Key, Map, Default) when is_map(Map) ->
    maps:get(
        Key,
        Map,
        maps:get(
            atom_to_binary(Key, utf8),
            Map,
            maps:get(atom_to_list(Key), Map, Default)
        )
    );
value(_, _, Default) ->
    Default.

bin(V) when is_binary(V) -> V;
bin(V) when is_list(V) -> unicode:characters_to_binary(V);
bin({_, Value}) -> bin(Value);
bin(_) -> <<>>.

boolean(false) -> false;
boolean(<<"false">>) -> false;
boolean(_) -> true.

fetch_registry_transactions() ->
    case registry_call(fun damage_node_registry:contract_id/0) of
        {ok, Contract} when is_binary(Contract), byte_size(Contract) > 3 ->
            fetch_registry_transactions(Contract);
        _ ->
            {error, registry_contract_unavailable}
    end.

fetch_registry_transactions(Contract) ->
    case registry_call(fun damage_ae:get_ae_mdw_node/0) of
        {ok, {ok, ConnPid, Prefix0}} ->
            try
                Prefix = bin(Prefix0),
                Q = uri_string:compose_query([
                    {"type", "contract_call"},
                    {"contract", binary_to_list(Contract)},
                    {"direction", "backward"},
                    {"limit", integer_to_list(?MDW_LIMIT)}
                ]),
                Path = iolist_to_binary([Prefix, "v3/transactions?", Q]),
                Stream = gun:get(ConnPid, Path, [{<<"accept">>, <<"application/json">>}]),
                case gun:await(ConnPid, Stream, ?MDW_TIMEOUT) of
                    {response, nofin, 200, _} ->
                        case gun:await_body(ConnPid, Stream, ?MDW_TIMEOUT) of
                            {ok, Body} -> decode_index_page(Body);
                            _ -> {error, middleware_timeout}
                        end;
                    {response, fin, 200, _} ->
                        {ok, []};
                    {response, _, Status, _} ->
                        {error, {middleware_status, Status}};
                    Other ->
                        {error, {middleware_response, Other}}
                end
            catch
                Class:Reason -> {error, {middleware_failed, Class, Reason}}
            after
                try
                    gun:close(ConnPid)
                catch
                    _:_ -> ok
                end
            end;
        _ ->
            {error, middleware_unavailable}
    end.

decode_index_page(Body) ->
    try jsx:decode(Body, [return_maps]) of
        #{<<"data">> := Rows} when is_list(Rows) -> {ok, Rows};
        #{data := Rows} when is_list(Rows) -> {ok, Rows};
        _ -> {error, invalid_middleware_response}
    catch
        _:_ -> {error, invalid_middleware_json}
    end.

register_ids(Row) when is_map(Row) ->
    F = bin(
        first(
            Row,
            [
                <<"function">>,
                <<"function_name">>,
                <<"entrypoint">>,
                <<"call_name">>,
                <<"func">>
            ],
            <<>>
        )
    ),
    Args = first(Row, [<<"arguments">>, <<"args">>, <<"decoded_args">>], []),
    Direct =
        case binary:match(F, <<"register_node">>) of
            nomatch ->
                [];
            _ when is_list(Args), length(Args) >= 2 ->
                case address_value(lists:nth(2, Args)) of
                    <<>> -> [];
                    Id -> [Id]
                end;
            _ ->
                []
        end,
    Children = [
        first(Row, [K], undefined)
     || K <- [
            <<"payload">>,
            <<"tx">>,
            <<"transaction">>,
            <<"call_info">>,
            <<"inner_tx">>
        ]
    ],
    Direct ++ lists:append([register_ids(C) || C <- Children]);
register_ids(List) when is_list(List) ->
    lists:append([register_ids(X) || X <- List]);
register_ids(_) ->
    [].

first(Map, [Key | Rest], Default) ->
    case maps:get(Key, Map, undefined) of
        undefined -> first(Map, Rest, Default);
        Value -> Value
    end;
first(_, [], Default) ->
    Default.

bad_address() -> {400, #{status => <<"error">>, error => <<"invalid AE address">>}}.
unavailable() -> {503, #{status => <<"error">>, error => <<"node registry unavailable">>}}.
