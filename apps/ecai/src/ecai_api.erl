-module(ecai_api).
-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([init/2]).
-export([content_types_accepted/2]).
-export([content_types_provided/2]).
-export([to_json/2]).
-export([from_json/2, allowed_methods/2]).
-export([is_authorized/2]).
-export([trails/0]).

-define(TRAILS_TAG, ["ECAI Api"]).
%% API Routes
trails() ->
    [
        trails:trail(
            "/ecai/ekef",
            ?MODULE,
            #{action => encode},
            #{
                description => "EKEF encoding endpoint",
                methods => #{
                    post => #{
                        tags => ?TRAILS_TAG,
                        description => "Mint a subject/predicate/object/context fact on-chain using a server-side signer",
                        parameters => [
                            #{
                                name => <<"subject">>,
                                type => <<"string">>,
                                required => true,
                                description => "Subject"
                            },
                            #{
                                name => <<"predicate">>,
                                type => <<"string">>,
                                required => true,
                                description => "Predicate"
                            },
                            #{
                                name => <<"object">>,
                                type => <<"string">>,
                                required => true,
                                description => "Object"
                            },
                            #{
                                name => <<"context">>,
                                type => <<"string">>,
                                required => true,
                                description => "Context"
                            }
                        ],
                        responses =>
                            #{
                                <<"200">> =>
                                    #{
                                        description => "Successful response",
                                        content => #{
                                            <<"application/json">> => #{
                                                <<"schema">> => #{
                                                    <<"type">> => <<"object">>
                                                }
                                            }
                                        }
                                    },
                                <<"400">> => #{description => "Bad request"}
                            }
                    }
                }
            }
        ),
        trails:trail("/v1/chat/completions", ecai_api, #{action => chat_completions}, #{
            description => "OpenAI-Compatible Chat API",
            methods => #{
                post => #{
                    tags => ?TRAILS_TAG,
                    description => "Generate an ECAI-backed completion. Supply messages or a legacy message; uses authenticated principal for memory isolation.",
                    parameters => [
                        #{
                            name => <<"messages">>,
                            type => <<"array">>,
                            required => false,
                            description => "OpenAI-style messages array, including a user message"
                        },
                        #{
                            name => <<"message">>,
                            type => <<"string">>,
                            required => false,
                            description => "Legacy user prompt, alternative to messages"
                        },
                        #{
                            name => <<"session_id">>,
                            type => <<"string">>,
                            required => false,
                            description => "Optional stable session ID"
                        }
                    ],
                    responses =>
                        #{
                            <<"200">> =>
                                #{
                                    description => "Successful response",
                                    content => #{
                                        <<"application/json">> => #{
                                            <<"schema">> => #{
                                                <<"type">> => <<"object">>
                                            }
                                        }
                                    }
                                },
                            <<"400">> => #{description => "Bad request"}
                        }
                }
            }
        }),
        %% /ecai/search – free-text search endpoint
        trails:trail("/ecai/search", ecai_api, #{action => search}, #{
            description => "Free-text ECAI search",
            methods => #{
                post => #{
                    tags => ?TRAILS_TAG,
                    description => "Search documents",
                    parameters => [
                        #{
                            name => <<"q">>,
                            type => <<"string">>,
                            required => true,
                            description => "Query string"
                        },
                        #{
                            name => <<"limit">>,
                            type => <<"integer">>,
                            required => false,
                            description => "Max results (default 10)"
                        }
                    ],
                    responses => #{
                        <<"200">> => #{description => "OK"},
                        <<"400">> => #{description => "Bad request"}
                    }
                }
            }
        })
    ].

%% Handle incoming requests
init(Req, Opts) -> {cowboy_rest, Req, Opts}.
is_authorized(Req, #{action := search} = State) ->
    {true, Req, State};
is_authorized(Req, State) ->
    damage_http:is_authorized(Req, State).

%% These endpoints are JSON-only. The historical HTML/YAML callbacks were
%% not implemented; advertising them caused Cowboy dispatch failures.
content_types_provided(Req, State) ->
    {[{{<<"application">>, <<"json">>, []}, to_json}], Req, State}.

content_types_accepted(Req, State) ->
    {[{{<<"application">>, <<"json">>, '*'}, from_json}], Req, State}.

allowed_methods(Req, #{action := get_knowledge} = State) ->
    {[<<"GET">>], Req, State};
allowed_methods(Req, State) ->
    {[<<"POST">>], Req, State}.
to_json(Req, #{ae_account := _AeAccount, action := get_knowledge} = State) ->
    case cowboy_req:match_qs([hash], Req) of
        #{hash := KnowledgeTxHash} ->
            Knowledge = get_knowledge(KnowledgeTxHash),
            {jsx:encode(Knowledge), Req, State};
        Other ->
            ?LOG_DEBUG("Unexpected ~p", [Other]),
            {<<"Invalid hash.">>, Req, State}
    end.

from_json(Req, #{action := search} = State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req),
    case ecai_otp_compat:catch_value(fun() -> jsx:decode(Body, [return_maps]) end) of
        #{<<"q">> := Q} = M ->
            Limit =
                case maps:get(<<"limit">>, M, 10) of
                    L when is_integer(L), L > 0 -> L;
                    _ -> 10
                end,
            Ctx =
                ecai_search_server:get_ctx(),
            %% Free-text → search all fields with prefix matching
            ?LOG_DEBUG("ecai query ~p", [Q]),
            {Results, Proofs} =
                ecai_search:search(
                    Ctx,
                    #{
                        name => Q,
                        category => Q,
                        city => Q,
                        tags => [Q],
                        phone => Q,
                        prefix => true
                    },
                    Limit
                ),
            Resp = #{
                <<"ok">> => true,
                <<"results">> => Results,
                <<"proofs">> => Proofs
            },
            {stop,
                cowboy_req:reply(
                    200,
                    #{<<"content-type">> => <<"application/json">>},
                    jsx:encode(Resp),
                    Req1
                ),
                State};
        _ ->
            {stop, cowboy_req:reply(400, Req), State}
    end;
%% The EKEF path is an on-chain operation, not a generic hash or encoder.
%% It must never accept a signer supplied in the HTTP payload.
from_json(Req, #{action := encode} = State) ->
    case read_json_object(Req) of
        {ok, #{<<"subject">> := Subject, <<"predicate">> := Predicate,
               <<"object">> := Object, <<"context">> := Context}, Req1}
            when is_binary(Subject), is_binary(Predicate),
                 is_binary(Object), is_binary(Context),
                 byte_size(Subject) > 0, byte_size(Subject) =< 4096,
                 byte_size(Predicate) > 0, byte_size(Predicate) =< 4096,
                 byte_size(Object) > 0, byte_size(Object) =< 4096,
                 byte_size(Context) > 0, byte_size(Context) =< 4096 ->
            Knowledge = #{subject => Subject, predicate => Predicate,
                          object => Object, context => Context},
            case maps:get(ae_account, State, undefined) of
                #{public_key := PublicKey, private_key := PrivateKey} = KeyPair
                    when is_binary(PublicKey), is_binary(PrivateKey) ->
                    case ecai_otp_compat:catch_value(fun() ->
                        ecai_nft:mint_knowledge(KeyPair, Knowledge)
                    end) of
                        {ok, MintResult} ->
                            reply_api_json(Req1, 200,
                                #{ok => true, result => MintResult}, State);
                        _ ->
                            %% Do not leak signer/key metadata in error responses.
                            reply_api_json(Req1, 502,
                                #{ok => false, error => <<"knowledge_mint_failed">>}, State)
                    end;
                _ ->
                    reply_api_json(Req1, 503,
                        #{ok => false, error => <<"server_signer_unavailable">>}, State)
            end;
        {ok, _, Req1} ->
            reply_api_json(Req1, 400,
                #{ok => false, error => <<"invalid_knowledge_fields">>}, State);
        {error, Req1} ->
            reply_api_json(Req1, 400,
                #{ok => false, error => <<"invalid_json">>}, State)
    end;
from_json(Req, #{action := chat_completions} = State) ->
    case read_json_object(Req) of
        {ok, Body, Req1} ->
            case {authenticated_principal(State), chat_message(Body)} of
                {{ok, Principal}, {ok, Message}} ->
                    Session = case maps:get(<<"session_id">>, Body, undefined) of
                        Value when is_binary(Value), byte_size(Value) > 0,
                                   byte_size(Value) =< 256 -> Value;
                        _ -> binary:encode_hex(crypto:strong_rand_bytes(16))
                    end,
                    Model = case maps:get(<<"model">>, Body, undefined) of
                        V when is_binary(V), byte_size(V) > 0 -> V;
                        _ -> <<"ecai">>
                    end,
                    case ecai_otp_compat:catch_value(fun() ->
                        ecai_chat:get_reply(Session, Principal, Message)
                    end) of
                        {ok, Reply} when is_binary(Reply) ->
                            Id = <<"chatcmpl-", (binary:encode_hex(crypto:strong_rand_bytes(8)))/binary>>,
                            reply_api_json(Req1, 200, #{
                                id => Id, object => <<"chat.completion">>,
                                created => erlang:system_time(second), model => Model,
                                choices => [#{index => 0,
                                    message => #{role => <<"assistant">>, content => Reply},
                                    finish_reason => <<"stop">>}],
                                reply => Reply
                            }, State);
                        _ ->
                            reply_api_json(Req1, 503,
                                #{error => #{message => <<"ecai_chat_unavailable">>}}, State)
                    end;
                {{error, _}, _} ->
                    reply_api_json(Req1, 401,
                        #{error => #{message => <<"unauthenticated">>}}, State);
                {_, {error, _}} ->
                    reply_api_json(Req1, 400,
                        #{error => #{message => <<"invalid_chat_message">>}}, State)
            end;
        {error, Req1} ->
            reply_api_json(Req1, 400,
                #{error => #{message => <<"invalid_json">>}}, State)
    end.

read_json_object(Req0) ->
    case cowboy_req:read_body(Req0, #{length => 65536, period => 5000}) of
        {ok, Raw, Req1} ->
            case ecai_otp_compat:catch_value(fun() ->
                jsx:decode(Raw, [return_maps])
            end) of
                Value when is_map(Value) -> {ok, Value, Req1};
                _ -> {error, Req1}
            end;
        {more, _Partial, Req1} -> {error, Req1}
    end.

chat_message(#{<<"messages">> := Messages}) when is_list(Messages) ->
    UserMessages = [Content || #{<<"role">> := <<"user">>,
                                <<"content">> := Content} <- Messages,
                                is_binary(Content)],
    case UserMessages of
        [] -> {error, missing_user_message};
        _ -> valid_chat_message(lists:last(UserMessages))
    end;
chat_message(#{<<"message">> := Message}) ->
    valid_chat_message(Message);
chat_message(_) -> {error, missing_user_message}.

valid_chat_message(Value) when is_binary(Value), byte_size(Value) > 0,
                               byte_size(Value) =< 16384 -> {ok, Value};
valid_chat_message(_) -> {error, invalid_chat_message}.

authenticated_principal(State) ->
    case ecai_otp_compat:catch_value(fun() ->
        damage_auth:authenticated_account(State)
    end) of
        {ok, AuthOwner} when is_binary(AuthOwner), byte_size(AuthOwner) > 0 ->
            {ok, AuthOwner};
        _ ->
            case maps:get(ae_account, State, undefined) of
                #{public_key := SignerOwner} when is_binary(SignerOwner) ->
                    {ok, SignerOwner};
                LegacyOwner when is_binary(LegacyOwner), byte_size(LegacyOwner) > 0 ->
                    {ok, LegacyOwner};
                _ -> {error, unauthenticated}
            end
    end.

reply_api_json(Req0, Status, Result, State) ->
    Req1 = cowboy_req:reply(
        Status, #{<<"content-type">> => <<"application/json">>},
        jsx:encode(Result), Req0),
    {stop, Req1, State}.

read_stream(ConnPid, StreamRef) ->
    case gun:await(ConnPid, StreamRef, 600000) of
        {response, nofin, Status, _Headers0} ->
            {ok, Body} = gun:await_body(ConnPid, StreamRef),
            ?LOG_DEBUG("read_stream Status ~p Response: ~p", [Status, Body]),
            jsx:decode(Body, [{labels, atom}, return_maps]);
        Default ->
            ?LOG_DEBUG("Got unexpected response ~p.", [Default]),
            Default
    end.

get_knowledge(KnowledgeTxHash) ->
    {ok, KnowledgeNftContract} = application:get_env(damage, knowledge_contract),
    case damage_ae:get_ae_mdw_node() of
        {ok, ConnPid, PathPrefix} ->
            Path =
                PathPrefix ++ "v3/aex141/" ++ KnowledgeNftContract ++ "/tokens/" ++ KnowledgeTxHash,
            StreamRef = gun:get(ConnPid, Path),
            MetaData =
                case ecai_otp_compat:catch_value(fun() -> read_stream(ConnPid, StreamRef) end) of
                    #{amount := null} ->
                        0;
                    {error, Error} ->
                        ?LOG_ERROR("Error getting balance ~p", [Error]),
                        0;
                    #{error := Error} ->
                        ?LOG_ERROR("Error getting balance ~p", [Error]),
                        0;
                    #{amount := Balance0} ->
                        Balance0
                end,
            {reply, MetaData};
        Err ->
            ?LOG_DEBUG("Finding ae node failed ~p", [Err]),
            {reply, {error, not_found}}
    end.
