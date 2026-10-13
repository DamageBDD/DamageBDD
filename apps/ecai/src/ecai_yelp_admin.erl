%%%-------------------------------------------------------------------
%%% ecai_yelp_admin.erl — Cowboy handler for Yelp/IPFS/ECAI admin ops
%%%-------------------------------------------------------------------
-module(ecai_yelp_admin).
-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-behaviour(cowboy_handler).

-export([init/2]).
-export([trails/0]).
-export([get_k_chunks/0]).
-define(JSON, <<"application/json">>).

-include_lib("kernel/include/logger.hrl").

%% Route in your cowboy router like:
%% {"/yelp/chunk",   ecai_yelp_admin, #{action => chunk}}
%% {"/yelp/ipfs",    ecai_yelp_admin, #{action => ipfs}}
%% {"/yelp/assign",  ecai_yelp_admin, #{action => assign}}
%% {"/yelp/headers", ecai_yelp_admin, #{action => headers}}
%% {"/yelp/manifest",ecai_yelp_admin, #{action => manifest}}
%% {"/yelp/status",  ecai_yelp_admin, #{action => status}}

%% # 0) status (empty)
%% curl -s http://127.0.0.1:8080/yelp/status | jq
%%
%% # start (async) — either route works if you kept both
%% curl -s -XPOST http://127.0.0.1:8080/yelp/chunk \
%%   -H 'content-type: application/json' \
%%   -d '{"in":"yelp_academic_dataset_business.json","out_dir":"chunks","chunk_size":5000}'
%%
%% # or explicitly:
%% curl -s -XPOST http://127.0.0.1:8080/yelp/chunk_async \
%%   -H 'content-type: application/json' \
%%   -d '{"in":"yelp_academic_dataset_business.json","out_dir":"chunks","chunk_size":5000}'
%%
%% # poll
%% curl -s http://127.0.0.1:8080/yelp/chunk_job | jq
%%
%% # cancel if needed
%% curl -s -XPOST http://127.0.0.1:8080/yelp/chunk_cancel | jq
%%
%% # continue your existing flow:
%% curl -s -XPOST http://127.0.0.1:8080/yelp/ipfs     | jq
%% curl -s -XPOST http://127.0.0.1:8080/yelp/assign   -d '{"cluster_id":0,"cluster_size":4}' -H 'content-type: application/json' | jq
%%
%% # 2) pin chunks to IPFS (CIDv1)
%% curl -s -XPOST http://127.0.0.1:8080/yelp/ipfs | jq
%%
%% # 3) assign to this node (shard 0/4)
%% curl -s -XPOST http://127.0.0.1:8080/yelp/assign \
%%   -H 'content-type: application/json' -d '{"cluster_id":0,"cluster_size":4}' | jq
%%
%% # 4) index assigned chunks (no limit)
%%
%% # 5) export headers (term roots)
%% curl -s -XPOST http://127.0.0.1:8080/yelp/headers | jq
%%
%% # 6) build manifest (Merkle root of CIDs + headers)
%% curl -s -XPOST http://127.0.0.1:8080/yelp/manifest | jq
%%
%% # 7) status
%% curl -s http://127.0.0.1:8080/yelp/status | jq
%% # start (returns 202 + job_id)
%%
%% # poll progress

%% persistent_term keys this module uses:

%% ecai_search ctx
%% [PathBin]
-define(K_CHUNKS, ecai_admin_chunks).
%% [{PathBin,CIDBin}]
-define(K_CHUNK_CID, ecai_admin_chunk_cids).
%% [PathBin]
-define(K_ASSIGN, ecai_admin_assigned).
%% export_onchain_headers/1
-define(K_HEADERS, ecai_admin_headers).
%% #{cids:=..., merkle_root:=..., headers:=...}
-define(K_MANIFEST, ecai_admin_manifest).
-define(ECAI_YELP_DATA_DIR, "/var/lib/damage/ecai/data/yelp/").

-define(TRAILS_TAG, ["ECAI Yelp Admin"]).
%% API Routes
trails() ->
    [
        %% === Yelp Admin API ===
        trails:trail("/yelp/chunk", ecai_yelp_admin, #{action => chunk}, #{
            description => "Split Yelp NDJSON dataset into chunks",
            methods => #{
                post => #{
                    tags => ["ECAI Yelp"],
                    description => "Chunk NDJSON Yelp data",
                    parameters => [
                        #{
                            name => <<"in">>,
                            type => <<"string">>,
                            required => true,
                            description => "Input Yelp NDJSON file path"
                        },
                        #{
                            name => <<"out_dir">>,
                            type => <<"string">>,
                            required => true,
                            description => "Output directory for chunks"
                        },
                        #{
                            name => <<"chunk_size">>,
                            type => <<"integer">>,
                            required => true,
                            description => "Number of lines per chunk"
                        }
                    ],
                    responses => #{
                        <<"200">> => #{description => "OK"},
                        <<"400">> => #{description => "Bad request"}
                    }
                }
            }
        }),
        trails:trail("/yelp/ipfs", ecai_yelp_admin, #{action => ipfs}, #{
            description => "Add all chunk files to IPFS and store CIDs",
            methods => #{
                post => #{
                    tags => ["ECAI Yelp"],
                    description => "Pin Yelp chunks to IPFS",
                    responses => #{
                        <<"200">> => #{description => "CIDs returned"},
                        <<"400">> => #{description => "Missing chunks"}
                    }
                }
            }
        }),
        trails:trail("/yelp/assign", ecai_yelp_admin, #{action => assign}, #{
            description => "Assign chunk subset to this node (for sharded indexing)",
            methods => #{
                post => #{
                    tags => ["ECAI Yelp"],
                    description => "Select shards to index",
                    parameters => [
                        #{name => <<"cluster_id">>, type => <<"integer">>, required => true},
                        #{name => <<"cluster_size">>, type => <<"integer">>, required => true}
                    ],
                    responses => #{
                        <<"200">> => #{description => "Assigned chunks"},
                        <<"400">> => #{description => "No chunks"}
                    }
                }
            }
        }),
        trails:trail("/yelp/headers", ecai_yelp_admin, #{action => headers}, #{
            description => "Export on-chain term headers (Merkle roots per term)",
            methods => #{
                post => #{
                    tags => ["ECAI Yelp"],
                    description => "Collect and cache headers from index",
                    responses => #{
                        <<"200">> => #{description => "Headers exported"}
                    }
                }
            }
        }),
        trails:trail("/yelp/manifest", ecai_yelp_admin, #{action => manifest}, #{
            description => "Build manifest with Merkle root of CIDs + term headers",
            methods => #{
                post => #{
                    tags => ["ECAI Yelp"],
                    description => "Create manifest to anchor on-chain",
                    responses => #{
                        <<"200">> => #{description => "Manifest ready"},
                        <<"400">> => #{description => "Missing data"}
                    }
                }
            }
        }),
        trails:trail("/yelp/status", ecai_yelp_admin, #{action => status}, #{
            description => "Get current Yelp loader/indexing status",
            methods => #{
                get => #{
                    tags => ["ECAI Yelp"],
                    description => "Status of chunks, CIDs, headers, etc.",
                    responses => #{
                        <<"200">> => #{description => "Status JSON"}
                    }
                }
            }
        }),
        trails:trail("/yelp/chunk_async", ecai_yelp_admin, #{action => chunk_async}, #{
            description => "Start async Yelp chunking job",
            methods => #{
                post => #{
                    tags => ["ECAI Yelp"],
                    responses => #{<<"202">> => #{description => "Started or busy"}}
                }
            }
        }),
        trails:trail("/yelp/chunk_job", ecai_yelp_admin, #{action => chunk_job}, #{
            description => "Get current Yelp chunk job status",
            methods => #{
                get => #{
                    tags => ["ECAI Yelp"], responses => #{<<"200">> => #{description => "Status"}}
                }
            }
        }),
        trails:trail("/yelp/chunk_cancel", ecai_yelp_admin, #{action => chunk_cancel}, #{
            description => "Cancel Yelp chunk job",
            methods => #{
                post => #{
                    tags => ["ECAI Yelp"],
                    responses => #{<<"200">> => #{description => "Canceled/Not running"}}
                }
            }
        })
    ].
init(Req, #{action := Action} = State) ->
    Method = cowboy_req:method(Req),
    case {Method, Action} of
        {<<"POST">>, chunk} -> handle_chunk(Req, State);
        {<<"POST">>, ipfs} -> handle_ipfs(Req, State);
        {<<"POST">>, assign} -> handle_assign(Req, State);
        {<<"POST">>, headers} -> handle_headers(Req, State);
        {<<"POST">>, manifest} -> handle_manifest(Req, State);
        {<<"GET">>, status} -> handle_status(Req, State);
        {<<"POST">>, chunk_async} -> handle_chunk_async(Req, State);
        {<<"GET">>, chunk_job} -> handle_chunk_job(Req, State);
        {<<"POST">>, chunk_cancel} -> handle_chunk_cancel(Req, State);
        _ -> reply_json(Req, 404, #{ok => false, error => <<"not_found">>}, State)
    end.

%%%-------------------------------------------------------------------
%%% /yelp/chunk  POST  { "in": "...ndjson", "out_dir": "chunks", "chunk_size": 5000 }
%%% Now: starts an async job and returns 202 + job_id
%%%-------------------------------------------------------------------
handle_chunk(Req, State) ->
    with_json(Req, fun(#{<<"in">> := In, <<"out_dir">> := Out, <<"chunk_size">> := K}) ->
        InAbs = filename:join([?ECAI_YELP_DATA_DIR, "in", In]),
        OutAbs = filename:join([?ECAI_YELP_DATA_DIR, "out", Out]),
        case ecai_chunker:start(yelp, InAbs, OutAbs, K) of
            {ok, JobId} ->
                Body = jsx:encode(#{ok => true, job_id => JobId, status => running}),
                {ok, cowboy_req:reply(202, #{<<"content-type">> => ?JSON}, Body, Req), State};
            {error, busy} ->
                %% If a chunk job is already running, return its status.
                S = ecai_chunker:status(),
                reply_json(Req, 200, maps:merge(#{ok => true}, S), State);
            {error, Reason} ->
                reply_json(
                    Req,
                    400,
                    #{
                        ok => false,
                        error => <<"invalid_chunk_request">>,
                        reason => reason_binary(Reason)
                    },
                    State
                )
        end
    end).
handle_chunk_async(Req, State) ->
    with_json(Req, fun(#{<<"in">> := In, <<"out_dir">> := Out, <<"chunk_size">> := K}) ->
        InAbs = filename:join([?ECAI_YELP_DATA_DIR, "in", In]),
        OutAbs = filename:join([?ECAI_YELP_DATA_DIR, "out", Out]),
        case ecai_chunker:start(yelp, InAbs, OutAbs, K) of
            {ok, JobId} ->
                Body = jsx:encode(#{ok => true, job_id => JobId, status => running}),
                {ok, cowboy_req:reply(202, #{<<"content-type">> => ?JSON}, Body, Req), State};
            {error, busy} ->
                S = ecai_chunker:status(),
                reply_json(Req, 200, maps:merge(#{ok => true}, S), State);
            {error, Reason} ->
                reply_json(
                    Req,
                    400,
                    #{
                        ok => false,
                        error => <<"invalid_chunk_request">>,
                        reason => reason_binary(Reason)
                    },
                    State
                )
        end
    end).

handle_chunk_job(Req, State) ->
    S = ecai_chunker:status(),
    reply_json(Req, 200, maps:merge(#{ok => true}, S), State).

handle_chunk_cancel(Req, State) ->
    R = ecai_chunker:cancel(),
    reply_json(Req, 200, maps:merge(#{ok => true}, R), State).

%%%-------------------------------------------------------------------
%%% /yelp/ipfs  POST {}
%%% Pins all chunks recorded by /yelp/chunk
%%%-------------------------------------------------------------------
handle_ipfs(Req, State) ->
    case get_pt(?K_CHUNKS, []) of
        [] ->
            reply_json(Req, 400, #{ok => false, error => <<"no_chunks">>}, State);
        Paths ->
            P = ecai_yelp_loader:ipfs_add_chunks(Paths),
            persistent_term:put(?K_CHUNK_CID, P),
            reply_json(Req, 200, #{ok => true, pinned => P, count => length(P)}, State)
    end.

%%%-------------------------------------------------------------------
%%% /yelp/assign  POST { "cluster_id": 0, "cluster_size": 4 }
%%%-------------------------------------------------------------------
handle_assign(Req, State) ->
    with_json(Req, fun(
        #{
            <<"cluster_id">> := Id,
            <<"cluster_size">> := Size
        }
    ) ->
        Paths = get_pt(?K_CHUNKS, []),
        case Paths of
            [] ->
                reply_json(Req, 400, #{ok => false, error => <<"no_chunks">>}, State);
            _ ->
                Mine = ecai_yelp_loader:assign_chunks(Paths, Id, Size),
                persistent_term:put(?K_ASSIGN, Mine),
                reply_json(Req, 200, #{ok => true, assigned => Mine, count => length(Mine)}, State)
        end
    end).

%%%-------------------------------------------------------------------
%%% Creates ecai_search ctx on first call.
%%%-------------------------------------------------------------------
handle_headers(Req, State) ->
    Ctx = ensure_ctx(),
    H = ecai_yelp_loader:extract_headers(Ctx),
    persistent_term:put(?K_HEADERS, H),
    reply_json(Req, 200, #{ok => true, headers_count => length(H)}, State).

%%%-------------------------------------------------------------------
%%% /yelp/manifest  POST {}
%%%-------------------------------------------------------------------
handle_manifest(Req, State) ->
    ChunkCIDs = get_pt(?K_CHUNK_CID, []),
    Headers = get_pt(?K_HEADERS, []),
    case {ChunkCIDs, Headers} of
        {[], _} ->
            reply_json(Req, 400, #{ok => false, error => <<"no_chunk_cids">>}, State);
        {_, []} ->
            reply_json(Req, 400, #{ok => false, error => <<"no_headers">>}, State);
        _ ->
            Man = ecai_yelp_loader:build_manifest(ChunkCIDs, Headers),
            persistent_term:put(?K_MANIFEST, Man),
            RootHex = to_hex(maps:get(merkle_root, Man)),
            reply_json(
                Req,
                200,
                #{ok => true, manifest_root => RootHex, cids => maps:get(cids, Man, [])},
                State
            )
    end.

%%%-------------------------------------------------------------------
%%% /yelp/status  GET
%%%-------------------------------------------------------------------
handle_status(Req, State) ->
    Resp =
        case safe_get_ctx() of
            {ok, undefined} ->
                #{docs => 0, terms => 0, postings => 0};
            {error, _Reason} ->
                #{
                    ok => false,
                    message => <<"index not ready">>
                };
            {ok, Ctx} ->
                Sz =
                    ecai_search:size(Ctx),
                #{
                    ok => true,
                    chunks => length(get_pt(?K_CHUNKS, [])),
                    pinned => length(get_pt(?K_CHUNK_CID, [])),
                    assigned => length(get_pt(?K_ASSIGN, [])),
                    headers => length(get_pt(?K_HEADERS, [])),
                    have_ctx => Ctx =/= undefined,
                    index_size => Sz
                }
        end,
    reply_json(Req, 200, Resp, State).

ensure_ctx() ->
    ecai_search_server:get_ctx().

safe_get_ctx() ->
    try ecai_search_server:get_ctx() of
        Ctx -> {ok, Ctx}
    catch
        Class:Reason -> {error, {Class, Reason}}
    end.

get_pt(Key, Default) ->
    persistent_term:get(Key, Default).

with_json(Req, Fun) ->
    case cowboy_req:read_body(Req) of
        {ok, Body, Req1} ->
            case decode_json_map(Body) of
                {ok, M} -> Fun(M);
                error -> reply_json(Req1, 400, #{ok => false, error => <<"bad_json">>}, #{})
            end;
        {more, _Data, Req1} ->
            reply_json(Req1, 413, #{ok => false, error => <<"payload_too_large">>}, #{})
    end.

decode_json_map(Body) ->
    try jsx:decode(Body, [return_maps]) of
        M when is_map(M) -> {ok, M};
        _Other -> error
    catch
        _Class:_Reason -> error
    end.

reply_json(Req, Code, Map, State) ->
    Body = jsx:encode(Map),
    Headers = #{<<"content-type">> => ?JSON},
    {ok, cowboy_req:reply(Code, Headers, Body, Req), State}.

reason_binary(Reason) ->
    unicode:characters_to_binary(io_lib:format("~p", [Reason])).

to_hex(Bin) when is_binary(Bin) ->
    lists:flatten([io_lib:format("~2.16.0B", [X]) || <<X:8>> <= Bin]).

get_k_chunks() -> ?K_CHUNKS.
