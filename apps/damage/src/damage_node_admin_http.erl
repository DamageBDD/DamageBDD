-module(damage_node_admin_http).

-author("Steven Joseph <steven@stevenjoseph.in>").
-license("Apache-2.0").

-export([init/2]).
-export([content_types_accepted/2, content_types_provided/2]).
-export([from_json/2, to_json/2, allowed_methods/2, is_authorized/2]).
-export([trails/0]).

-include_lib("kernel/include/logger.hrl").
-include_lib("damage.hrl").

-define(TRAILS_TAG, ["Node Admin"]).

trails() ->
    [
        trails:trail(
            "/api/node_admin/transactions",
            damage_node_admin_http,
            #{action => transactions},
            #{
                get => #{
                    tags => ?TRAILS_TAG,
                    description => "Node admin Lightning and Bitcoin transactions.",
                    produces => ["application/json"]
                }
            }
        ),
        trails:trail(
            "/api/node_admin/channels",
            damage_node_admin_http,
            #{action => channels},
            #{
                get => #{
                    tags => ?TRAILS_TAG,
                    description => "Node admin CLN channels and balances.",
                    produces => ["application/json"]
                }
            }
        ),
        trails:trail(
            "/api/node_admin/best_peers",
            damage_node_admin_http,
            #{action => best_peers},
            #{
                get => #{
                    tags => ?TRAILS_TAG,
                    description => "Suggest best peers to open channels with.",
                    produces => ["application/json"]
                }
            }
        ),
        trails:trail(
            "/api/node_admin/connect_peer",
            damage_node_admin_http,
            #{action => connect_peer},
            #{
                post => #{
                    tags => ?TRAILS_TAG,
                    description => "Connect to a peer.",
                    consumes => ["application/json"],
                    produces => ["application/json"]
                }
            }
        ),
        trails:trail(
            "/api/node_admin/open_channel",
            damage_node_admin_http,
            #{action => open_channel},
            #{
                post => #{
                    tags => ?TRAILS_TAG,
                    description => "Open a channel with a peer.",
                    consumes => ["application/json"],
                    produces => ["application/json"]
                }
            }
        ),
        trails:trail(
            "/api/node_admin/open_best_channels",
            damage_node_admin_http,
            #{action => open_best_channels},
            #{
                post => #{
                    tags => ?TRAILS_TAG,
                    description => "Open channels with best peers.",
                    consumes => ["application/json"],
                    produces => ["application/json"]
                }
            }
        )
    ].

init(Req, Opts) ->
    {cowboy_rest, Req, Opts}.

allowed_methods(Req, State = #{action := Action}) ->
    Methods =
        case Action of
            transactions -> [<<"GET">>];
            channels -> [<<"GET">>];
            best_peers -> [<<"GET">>];
            connect_peer -> [<<"POST">>];
            open_channel -> [<<"POST">>];
            open_best_channels -> [<<"POST">>]
        end,
    {Methods, Req, State}.

content_types_provided(Req, State) ->
    {[{{<<"application">>, <<"json">>, []}, to_json}], Req, State}.

content_types_accepted(Req, State) ->
    {[{{<<"application">>, <<"json">>, '*'}, from_json}], Req, State}.

is_authorized(Req, State) ->
    case damage_http:is_authorized(Req, State) of
        {true, Req1, AuthState} ->
            case is_node_admin(AuthState) of
                true ->
                    {true, Req1, AuthState};
                false ->
                    {{false, <<"Forbidden">>}, Req1, AuthState}
            end;
        Other ->
            Other
    end.

is_node_admin(State) when is_map(State) ->
    maps:get(node_admin, State, false);
is_node_admin(_) ->
    false.

to_json(Req, #{action := transactions} = State) ->
    LimitBin = cowboy_req:qs_val(<<"limit">>, Req, <<"50">>),
    Limit =
        case LimitBin of
            B when is_binary(B) ->
                try
                    binary_to_integer(B)
                catch
                    _:_ -> 50
                end;
            I when is_integer(I) -> I;
            _ ->
                50
        end,

    Funds0 = cln:list_funds(),
    Onchain0 = maps:get(outputs, Funds0, []),
    FundingChannels0 = maps:get(channels, Funds0, []),

    {ok, Invoices0} = cln:list_all_invoices(#{page_limit => Limit, order => desc}),
    Pays0 = cln:list_pays(),
    SendPays0 = cln:list_sendpays(),

    Pays =
        case Pays0 of
            #{pays := L} when is_list(L) ->
                Pays0#{pays := cln:sort_pays_desc(L)};
            _ ->
                Pays0
        end,

    SendPays =
        case SendPays0 of
            #{payments := L0} when is_list(L0) ->
                SendPays0#{payments := cln:sort_sendpays_desc(L0)};
            _ ->
                SendPays0
        end,

    Body =
        #{
            ok => true,
            onchain => Funds0#{
                outputs => cln:sort_outputs_desc(Onchain0),
                channels => cln:sort_peerchannels_desc(FundingChannels0)
            },
            lightning => #{
                pays => Pays,
                sendpays => SendPays,
                invoices => #{invoices => Invoices0}
            }
        },
    {jsx:encode(Body), Req, State};
to_json(Req, #{action := channels} = State) ->
    Channels0 = cln:list_channels(),
    SortedChannels = cln:sort_peerchannels_desc(Channels0),
    Body =
        #{
            ok => true,
            balance => cln:get_node_balance(),
            channels => SortedChannels
        },
    {jsx:encode(Body), Req, State};
to_json(Req, #{action := best_peers} = State) ->
    {AmountMsat0, Req1} = cowboy_req:qs_val(<<"amount_msat">>, Req, <<"200000000">>),
    AmountMsat =
        case AmountMsat0 of
            B when is_binary(B) -> binary_to_integer(B);
            I when is_integer(I) -> I;
            _ -> 200000000
        end,
    AmountSats = AmountMsat div 1000,
    Body =
        #{
            ok => true,
            amount_msat => AmountMsat,
            amount_sats => AmountSats,
            best_peers => cln:find_best_peer_to_open(AmountSats)
        },
    {jsx:encode(Body), Req1, State}.

from_json(Req, #{action := connect_peer} = State) ->
    {ok, Raw, Req1} = cowboy_req:read_body(Req),
    Data = jsx:decode(Raw, [return_maps, {labels, atom}]),
    Peer = maps:get(peer, Data),
    Reply = cln:connect_peer(Peer),
    reply_json(Req1, State, #{ok => true, result => Reply});
from_json(Req, #{action := open_channel} = State) ->
    {ok, Raw, Req1} = cowboy_req:read_body(Req),
    Data = jsx:decode(Raw, [return_maps, {labels, atom}]),
    Peer = maps:get(peer, Data),
    AmountSats = maps:get(amount_sats, Data, 200000),
    Reply = cln:open_channel(Peer, AmountSats),
    reply_json(Req1, State, #{ok => true, result => Reply});
from_json(Req, #{action := open_best_channels} = State) ->
    {ok, Raw, Req1} = cowboy_req:read_body(Req),
    Data = jsx:decode(Raw, [return_maps, {labels, atom}]),
    Reply = cln:open_channels_with_best_peers(Data),
    reply_json(Req1, State, #{ok => true, result => Reply}).

reply_json(Req, State, Body) ->
    Req1 = cowboy_req:reply(
        200,
        #{<<"content-type">> => <<"application/json">>},
        jsx:encode(Body),
        Req
    ),
    {stop, Req1, State}.
