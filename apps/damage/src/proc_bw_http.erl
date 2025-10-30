-module(proc_bw_http).
-export([init/2]).
init(Req, _State) ->
    M = cowboy_req:method(Req),
    P = cowboy_req:path(Req),
    case {M, P} of
        {<<"POST">>, <<"/proc_bw/start">>} ->
            ensure_started(),
            {ok, cowboy_req:reply(200, #{}, <<"{\"ok\":true}">>, Req), undefined};
        {<<"DELETE">>, <<"/proc_bw/stop">>} ->
            proc_bw:stop_port(),
            {ok, cowboy_req:reply(200, #{}, <<"{\"ok\":true}">>, Req), undefined};
        {<<"GET">>, <<"/proc_bw/rates">>} ->
            J = jsx:encode(proc_bw:rates()),
            {ok, cowboy_req:reply(200, #{<<"content-type">> => <<"application/json">>}, J, Req),
                undefined};
        _ ->
            case string:tokens(binary_to_list(P), "/") of
                ["", "proc_bw", "rate", PidS] ->
                    Pid = list_to_integer(PidS),
                    R =
                        case proc_bw:rate(Pid) of
                            undefined -> #{ok => false};
                            M2 -> M2#{ok => true}
                        end,
                    J = jsx:encode(R),
                    {ok,
                        cowboy_req:reply(
                            200, #{<<"content-type">> => <<"application/json">>}, J, Req
                        ),
                        undefined};
                ["", "proc_bw", "assert"] ->
                    {Qs, _} = cowboy_req:qs(Req),
                    Pid = to_i(qget(Qs, <<"pid">>, <<"0">>)),
                    MinTx = to_i(qget(Qs, <<"min_tx">>, <<"0">>)),
                    MinRx = to_i(qget(Qs, <<"min_rx">>, <<"0">>)),
                    R2 = proc_bw:rate(Pid),
                    Ok =
                        case R2 of
                            #{tx_bps := Tx, rx_bps := Rx} when Tx >= MinTx, Rx >= MinRx -> true;
                            _ -> false
                        end,
                    J2 = jsx:encode(#{ok => Ok, rate => R2}),
                    {ok,
                        cowboy_req:reply(
                            200, #{<<"content-type">> => <<"application/json">>}, J2, Req
                        ),
                        undefined};
                _ ->
                    {ok, cowboy_req:reply(404, #{}, <<"{\"error\":\"not_found\"}">>, Req),
                        undefined}
            end
    end.

ensure_started() ->
    case whereis(proc_bw) of
        undefined -> proc_bw:start_link();
        _ -> ok
    end,
    proc_bw:start_port(),
    ok.

qget(Qs, K, D) ->
    case lists:keyfind(K, 1, Qs) of
        {_, V} -> V;
        false -> D
    end.
to_i(Bin) ->
    case string:to_integer(binary_to_list(Bin)) of
        {I, _} -> I;
        _ -> 0
    end.
