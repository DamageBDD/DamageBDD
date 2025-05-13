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
          ecai_api,
          #{action => encode},
          #{
            description => "EKEF encoding endpoint",
            methods => #{
                post => #{
                    tags => ?TRAILS_TAG,
                    description => "Get an AI-generated response",
                    parameters => [
                        #{
                            name => <<"session_id">>,
                            type => <<"string">>,
                            required => true,
                            description => "Unique chat session ID"
                        },
                        #{
                            name => <<"user_id">>,
                            type => <<"string">>,
                            required => true,
                            description => "User Identifier"
                        },
                        #{
                            name => <<"message">>,
                            type => <<"string">>,
                            required => true,
                            description => "User message input"
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
        trails:trail("/v1/chat/completions", ecai_api, #{}, #{
            description => "OpenAI-Compatible Chat API",
            methods => #{
                post => #{
                    tags => ?TRAILS_TAG,
                    description => "Get an AI-generated response",
                    parameters => [
                        #{
                            name => <<"session_id">>,
                            type => <<"string">>,
                            required => true,
                            description => "Unique chat session ID"
                        },
                        #{
                            name => <<"user_id">>,
                            type => <<"string">>,
                            required => true,
                            description => "User Identifier"
                        },
                        #{
                            name => <<"message">>,
                            type => <<"string">>,
                            required => true,
                            description => "User message input"
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
        })
    ].

%% Handle incoming requests
init(Req, Opts) -> {cowboy_rest, Req, Opts}.
is_authorized(Req, State) ->
    damage_http:is_authorized(Req, State).

content_types_provided(Req, State) ->
    {
        [
            {{<<"application">>, <<"json">>, []}, to_json},
            {{<<"text">>, <<"html">>, '*'}, to_html}
        ],
        Req,
        State
    }.

content_types_accepted(Req, State) ->
    {
        [
            {{<<"application">>, <<"x-www-form-urlencoded">>, '*'}, from_html},
            {{<<"application">>, <<"x-yaml">>, '*'}, from_yaml},
            {{<<"application">>, <<"json">>, '*'}, from_json}
        ],
        Req,
        State
    }.

allowed_methods(Req, State) ->
    {[<<"GET">>, <<"POST">>, <<"DELETE">>], Req, State}.
to_json(Req, #{ae_account := _AeAccount, action := get_knowledge} = State) ->
    case cowboy_req:match_qs([hash], Req) of
        #{hash := KnowledgeTxHash} ->
            Knowledge = get_knowledge(KnowledgeTxHash),
            {jsx:encode(Knowledge), Req, State};
        Other ->
            ?LOG_DEBUG("Unexpected ~p", [Other]),
            {<<"Invalid hash.">>, Req, State}
    end.

from_json(Req, #{ae_account := AeAccount, action := encode} = State) ->
    {ok, Data, Req0} = cowboy_req:read_body(Req),
    ?LOG_DEBUG("post action ~p ", [Data]),
    case catch jsx:decode(Data, [return_maps, {labels, atom}]) of
        #{
            subject := _Subject,
            predicate := _Predicate,
            object := _Object,
            context := _Context
        } when is_map(Data) ->
            Response = cowboy_req:set_resp_body(
                jsx:encode(ecai:mint_knowledge(AeAccount, Data)), Req0
            ),
            cowboy_req:reply(200, Response),
            {stop, Response, State};
        _ ->
            Response =
                cowboy_req:set_resp_body(
                    jsx:encode(
                        #{status => <<"failed">>, message => <<"Json decode error.">>}
                    ),
                    Req0
                ),
            cowboy_req:reply(400, Response),
            ?LOG_DEBUG("post response 400 ~p ", [Response]),
            {stop, Response, State}
    end;
from_json(Req, #{ae_account := AeAccount} = State) ->
    {ok, Data, Req0} = cowboy_req:read_body(Req),
    ?LOG_DEBUG("post action ~p ", [Data]),
    case catch jsx:decode(Data, [return_maps, {labels, atom}]) of
        #{<<"session_id">> := SessionID, <<"user_id">> := AeAccount, <<"message">> := Message} ->
            AIReply = ecai_chat:get_reply(SessionID, Message),
            Response = #{<<"reply">> => AIReply},
            {ok,
                cowboy_req:reply(
                    200, #{<<"content-type">> => <<"application/json">>}, jsx:encode(Response), Req0
                ),
                State};
        _ ->
            {ok, cowboy_req:reply(400, Req), State}
    end.

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
                case catch read_stream(ConnPid, StreamRef) of
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
