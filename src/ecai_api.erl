-module(ecai_api).
-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("damage.hrl").

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
        trails:trail("/v1/chat/completions", ecai_api, #{}, #{
            description => "OpenAI-Compatible Chat API",
            methods => #{
                post => #{
                    summary => "Get an AI-generated response",
                    tags => [chat],
                    request => #{
                        content => #{
                            "application/json" => #{
                                schema => #{
                                    type => object,
                                    properties => #{
                                        session_id => #{
                                            type => string, description => "Unique chat session ID"
                                        },
                                        user_id => #{
                                            type => string, description => "User identifier"
                                        },
                                        message => #{
                                            type => string, description => "User message input"
                                        }
                                    },
                                    required => [session_id, user_id, message]
                                }
                            }
                        }
                    },
                    responses => #{
                        200 => #{
                            description => "Successful response",
                            content => #{
                                "application/json" => #{
                                    schema => #{
                                        type => object,
                                        properties => #{
                                            reply => #{
                                                type => string,
                                                description => "AI-generated response"
                                            }
                                        }
                                    }
                                }
                            }
                        },
                        400 => #{description => "Bad request"}
                    }
                }
            }
        })
    ].

%% Handle incoming requests
init(Req, Opts) -> {cowboy_rest, Req, Opts}.
is_authorized(Req, State) -> damage_http:is_authorized(Req, State).

content_types_provided(Req, State) ->
    {
        [
            {{<<"application">>, <<"json">>, []}, to_json},
            %{{<<"text">>, <<"plain">>, '*'}, to_text},
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
to_json(Data) -> jsx:encode(Data).
reply_json(Req, Status, Body) ->
    cowboy_req:reply(Status, #{<<"content-type">> => <<"application/json">>}, to_json(Body), Req).

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

to_json(Req, _State) ->
    reply_json(Req, 404, #{error => <<"Not Found">>}).
