%% Shared NFT-only fixtures. No live keys, chain or IPFS state is required.
-module(damage_release_test_support).
-export([cid/0, digest/0, answer/0, release_record/0, metadata/0,
         installed_release/0, some/1, token_metadata/0,
         with_kubo/1, kubo_put/3, kubo_requests/1]).

cid() -> <<"QmXsQVyTPVPgzHxinfiaj7Vzf9SrWVkkGNAHNfdm8RtJXS">>.
digest() -> binary:copy(<<"a">>, 64).
answer() ->
    Cid = cid(),
    <<"42|v1.4.1|ubuntu-noble-amd64||ipfs://", Cid/binary, "|ipfs://", Cid/binary>>.
release_record() ->
    #{token_id => 42, release => <<"v1.4.1">>, platform => <<"ubuntu-noble-amd64">>,
      git_sha => <<>>, metadata_cid => cid(), asset_cid => cid()}.
metadata() ->
    #{<<"file_ipfs">> => cid(), <<"git_sha">> => <<>>,
      <<"installation">> => #{<<"schema_version">> => 1,
        <<"platform">> => <<"ubuntu-noble-amd64">>, <<"package_format">> => <<"deb">>,
        <<"architecture">> => <<"amd64">>, <<"asset_path">> => <<"damage.deb">>,
        <<"sha256">> => digest()}}.
installed_release() ->
    (release_record())#{schema_version => 2, network_id => <<"ae_mainnet">>,
        contract_id => <<"ct_test_fixture">>, metadata_verification => <<"local_kubo">>,
        asset_path => <<"damage.deb">>, sha256 => digest(),
        package_format => <<"deb">>, architecture => <<"amd64">>}.
some(Value) -> {variant, [0, 1], 1, {Value}}.
token_metadata() ->
    Cid = cid(),
    {variant, [1, 1], 1, {#{<<"release">> => <<"v1.4.1">>,
        <<"platform">> => <<"ubuntu-noble-amd64">>, <<"git_sha">> => <<>>,
        <<"url">> => <<"ipfs://", Cid/binary>>, <<"asset">> => <<"ipfs://", Cid/binary>>}}}.

%% A small loopback Kubo-RPC fixture used by publication integration tests.
%% It checks requested CID paths and length limits, but does NOT implement CID
%% block verification. The fixture CIDs are syntactic test identities only.
%% Run sequentially: the helper temporarily changes application configuration.
with_kubo(Fun) ->
    {ok, _} = application:ensure_all_started(crypto),
    {ok, _} = application:ensure_all_started(gun),
    Objects = ets:new(?MODULE, [set, protected]),
    try
        Requests = ets:new(?MODULE, [ordered_set, public]),
        try
            {ok, Listen} = gen_tcp:listen(0, [binary, {packet, http_bin},
                {active, false}, {reuseaddr, true}, {ip, {127,0,0,1}}]),
            try
                {ok, {_, Port}} = inet:sockname(Listen),
                {Peer, Monitor} = spawn_monitor(fun() ->
                    kubo_accept(Listen, Objects, Requests)
                end),
                try
                    with_release_env(Port, fun() -> Fun({Objects, Requests}) end)
                after
                    exit(Peer, kill),
                    receive {'DOWN', Monitor, process, Peer, _} -> ok
                    after 2000 ->
                        erlang:demonitor(Monitor, [flush]),
                        error(kubo_fixture_cleanup_timeout)
                    end
                end
            after
                gen_tcp:close(Listen)
            end
        after
            ets:delete(Requests)
        end
    after
        ets:delete(Objects)
    end.

kubo_put({Objects, _Requests}, Path, Bytes) when is_binary(Path), is_binary(Bytes) ->
    true = ets:insert(Objects, {<<"/ipfs/", Path/binary>>, Bytes}),
    ok.

kubo_requests({_Objects, Requests}) ->
    [Request || {_Sequence, Request} <- ets:tab2list(Requests)].

with_release_env(Port, Fun) ->
    Settings = [
        {ipfs_runtime, [{ipfs_api, "http://127.0.0.1:" ++ integer_to_list(Port)},
            {request_timeout_ms, 2000}]},
        {build_release_query_timeout, 2000},
        {build_release_publish_timeout, 5000},
        {build_release_require_installation, true},
        {build_release_announce_oracle, false}
    ],
    Saved = [{K, application:get_env(damage, K)} || {K, _} <- Settings],
    try
        lists:foreach(fun({K, V}) -> ok = application:set_env(damage, K, V) end, Settings),
        Fun()
    after
        lists:foreach(fun
            ({K, undefined}) -> application:unset_env(damage, K);
            ({K, {ok, Value}}) -> application:set_env(damage, K, Value)
        end, Saved)
    end.

kubo_accept(Listen, Objects, Requests) ->
    case gen_tcp:accept(Listen) of
        {ok, Sock} ->
            try kubo_request(Sock, Objects, Requests)
            after gen_tcp:close(Sock)
            end,
            kubo_accept(Listen, Objects, Requests);
        {error, closed} -> ok;
        {error, Reason} -> error({kubo_fixture_accept_failed, Reason})
    end.

kubo_request(Sock, Objects, Requests) ->
    case gen_tcp:recv(Sock, 0, 2000) of
        {ok, {http_request, 'POST', {abs_path, Target}, _Version}} ->
            ok = kubo_headers(Sock),
            #{path := <<"/api/v0/cat">>, query := Query} = uri_string:parse(Target),
            Params = uri_string:dissect_query(Query),
            Arg = proplists:get_value(<<"arg">>, Params),
            Limit = binary_to_integer(proplists:get_value(<<"length">>, Params)),
            true = (Limit > 0),
            true = ets:insert(Requests,
                {erlang:unique_integer([positive, monotonic]), {Arg, Limit}}),
            case ets:lookup(Objects, Arg) of
                [{Arg, Bytes}] ->
                    N = erlang:min(Limit, byte_size(Bytes)),
                    kubo_response(Sock, <<"200 OK">>, binary:part(Bytes, 0, N));
                [] -> kubo_response(Sock, <<"404 Not Found">>, <<"missing fixture object">>)
            end;
        {error, closed} -> ok;
        Other -> error({kubo_fixture_request_failed, Other})
    end.

kubo_headers(Sock) ->
    case gen_tcp:recv(Sock, 0, 2000) of
        {ok, {http_header, _, _, _, _}} -> kubo_headers(Sock);
        {ok, http_eoh} -> ok;
        Other -> error({kubo_fixture_headers_failed, Other})
    end.

kubo_response(Sock, Status, Bytes) ->
    gen_tcp:send(Sock, [<<"HTTP/1.1 ">>, Status,
        <<"\r\nConnection: close\r\nContent-Type: application/octet-stream\r\nContent-Length: ">>,
        integer_to_binary(byte_size(Bytes)), <<"\r\n\r\n">>, Bytes]).
