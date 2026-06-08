-module(ecai_chat_http_handler).

-author("Steven Joseph <steven@stevenjoseph.in>").
-copyright("Steven Joseph <steven@stevenjoseph.in>").
-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").

-export([
    init/2,
    trails/0,
    allowed_methods/2,
    content_types_provided/2,
    content_types_accepted/2,
    to_json/2,
    from_json/2
]).

-define(TRAILS_TAG, ["ECAI Chat"]).
%% 8MB
-define(DEFAULT_MAX_BODY, 8388608).

trails() ->
    [
        trails:trail(
            "/ecai/chat",
            ?MODULE,
            #{action => chat},
            #{
                get =>
                    #{
                        tags => ?TRAILS_TAG,
                        description => "Health check for the local ECAI chat endpoint.",
                        produces => ["application/json"]
                    },
                post =>
                    #{
                        tags => ?TRAILS_TAG,
                        description =>
                            "Ask the ECAI-backed local chat assistant using session/user context.",
                        consumes => ["application/json"],
                        produces => ["application/json"],
                        parameters =>
                            [
                                #{
                                    name => <<"session_id">>,
                                    description => <<"Stable chat session id. Defaults to emacs.">>,
                                    in => <<"body">>,
                                    required => false,
                                    type => <<"string">>
                                },
                                #{
                                    name => <<"user_id">>,
                                    description =>
                                        <<"User id for memory scoping. Defaults to steven.">>,
                                    in => <<"body">>,
                                    required => false,
                                    type => <<"string">>
                                },
                                #{
                                    name => <<"message">>,
                                    description => <<"Prompt/message to send to ECAI chat.">>,
                                    in => <<"body">>,
                                    required => true,
                                    type => <<"string">>
                                }
                            ]
                    }
            }
        ),
        trails:trail(
            "/ecai/chat/",
            ?MODULE,
            #{action => chat},
            #{
                get =>
                    #{
                        tags => ?TRAILS_TAG,
                        description => "Health check for the local ECAI chat endpoint.",
                        produces => ["application/json"]
                    },
                post =>
                    #{
                        tags => ?TRAILS_TAG,
                        description =>
                            "Ask the ECAI-backed local chat assistant using session/user context.",
                        consumes => ["application/json"],
                        produces => ["application/json"]
                    }
            }
        )
    ].

init(Req, Opts) ->
    {cowboy_rest, Req, Opts}.

allowed_methods(Req, State) ->
    {[<<"GET">>, <<"POST">>, <<"OPTIONS">>], Req, State}.

content_types_provided(Req, State) ->
    {
        [
            {{<<"application">>, <<"json">>, '*'}, to_json}
        ],
        Req,
        State
    }.

content_types_accepted(Req, State) ->
    {
        [
            {{<<"application">>, <<"json">>, '*'}, from_json}
        ],
        Req,
        State
    }.

to_json(Req, State = #{action := chat}) ->
    Body =
        jsx:encode(#{
            status => <<"ok">>,
            service => <<"ecai_chat">>,
            endpoint => <<"/ecai/chat">>
        }),
    {Body, Req, State}.

from_json(Req0, State = #{action := chat}) ->
    MaxBody = application:get_env(ecai, ecai_chat_max_body, ?DEFAULT_MAX_BODY),

    case read_full_body(Req0, <<>>, MaxBody) of
        {ok, Raw, Req1} ->
            handle_chat_json(Raw, Req1, State);
        {error, Reason, Req1} ->
            reply_json(
                413,
                #{status => <<"error">>, error => format_bin("body_error: ~p", [Reason])},
                Req1,
                State
            )
    end.

handle_chat_json(Raw, Req, State) ->
    try jsx:decode(Raw, [return_maps]) of
        Json when is_map(Json) ->
            SessionID = to_bin(maps:get(<<"session_id">>, Json, <<"emacs">>)),
            UserID = to_bin(maps:get(<<"user_id">>, Json, <<"steven">>)),
            Message = to_bin(maps:get(<<"message">>, Json, <<>>)),

            case Message of
                <<>> ->
                    reply_json(
                        400,
                        #{status => <<"error">>, error => <<"empty_message">>},
                        Req,
                        State
                    );
                _ ->
                    Resp = ask_ecai(SessionID, UserID, Message),
                    reply_json(200, Resp, Req, State)
            end;
        _ ->
            reply_json(
                400,
                #{status => <<"error">>, error => <<"json_body_must_be_object">>},
                Req,
                State
            )
    catch
        Class:Reason:Stack ->
            ?LOG_WARNING("Bad ecai_chat JSON request ~p:~p ~p", [Class, Reason, Stack]),
            reply_json(
                400,
                #{status => <<"error">>, error => format_bin("bad_json: ~p", [Reason])},
                Req,
                State
            )
    end.

ask_ecai(SessionID, UserID, Message) ->
    case catch ecai_chat:get_reply(SessionID, UserID, Message) of
        {ok, Reply} when is_binary(Reply) ->
            #{
                status => <<"ok">>,
                reply => Reply,
                session_id => SessionID,
                user_id => UserID
            };
        {ok, Reply} ->
            #{
                status => <<"ok">>,
                reply => format_bin("~p", [Reply]),
                session_id => SessionID,
                user_id => UserID
            };
        {error, Reason} ->
            #{
                status => <<"error">>,
                error => format_bin("~p", [Reason]),
                session_id => SessionID,
                user_id => UserID
            };
        {'EXIT', Reason} ->
            #{
                status => <<"error">>,
                error => format_bin("ecai_chat_exit: ~p", [Reason]),
                session_id => SessionID,
                user_id => UserID
            };
        Other ->
            #{
                status => <<"error">>,
                error => format_bin("unexpected_ecai_chat_reply: ~p", [Other]),
                session_id => SessionID,
                user_id => UserID
            }
    end.

reply_json(Status, Map, Req0, State) ->
    Req1 =
        cowboy_req:reply(
            Status,
            #{<<"content-type">> => <<"application/json">>},
            jsx:encode(Map),
            Req0
        ),
    {stop, Req1, State}.

read_full_body(Req0, Acc, MaxBody) ->
    case cowboy_req:read_body(Req0, #{length => MaxBody, period => 15000}) of
        {ok, Data, Req1} ->
            Body = <<Acc/binary, Data/binary>>,
            case byte_size(Body) =< MaxBody of
                true -> {ok, Body, Req1};
                false -> {error, too_large, Req1}
            end;
        {more, Data, Req1} ->
            Acc1 = <<Acc/binary, Data/binary>>,
            case byte_size(Acc1) =< MaxBody of
                true -> read_full_body(Req1, Acc1, MaxBody);
                false -> {error, too_large, Req1}
            end
    end.

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> unicode:characters_to_binary(L);
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_bin(I) when is_integer(I) -> integer_to_binary(I);
to_bin(Other) -> format_bin("~p", [Other]).

format_bin(Fmt, Args) ->
    iolist_to_binary(io_lib:format(Fmt, Args)).
