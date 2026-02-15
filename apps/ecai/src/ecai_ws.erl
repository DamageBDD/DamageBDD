-module(ecai_ws).

-author("Steven Joseph <steven@damagebdd.com>").
-copyright("Steven Joseph <steven@damagebdd.com>").
-license("Apache-2.0").
-include_lib("kernel/include/logger.hrl").
-include_lib("ecai.hrl").
-behaviour(cowboy_websocket).

-export([init/2, websocket_init/1, websocket_handle/2, websocket_info/2]).
-export([test/0]).

init(Req, State) ->
    %% or higher
    {cowboy_websocket, Req, State, #{idle_timeout => 60000}}.
%{cowboy_websocket, Req, #{}}.

websocket_init(State) ->
    erlang:send_after(30000, self(), ping),
    {ok, maps:put(keypair, undefined, State)}.

websocket_handle({text, Msg}, State) ->
    case jsx:decode(Msg, [return_maps, {labels, atom}]) of
        #{action := <<"get_price">>} ->
            {reply, {text, jsx:encode(#{type => <<"price">>, btc => price_feed:get_price()})},
                State};
        #{action := <<"ping">>} ->
            {reply, {text, jsx:encode(#{type => <<"pong">>})}, State};
        #{action := <<"pong">>} ->
            {reply, {text, jsx:encode(#{type => <<"pong">>})}, State};
        _ ->
            {reply, {text, jsx:encode(#{error => <<"invalid_request">>})}, State}
    end.

%% websocket_info/2 – ping every 30s
websocket_info(ping, State) ->
    erlang:send_after(30000, self(), ping),
    {reply, {text, jsx:encode(#{type => <<"ping">>})}, State};
websocket_info({chat, Chat} = Info, #{session_id := SessionId, ae_account := AeAccount} = State) ->
    ?LOG_INFO("ecai ws got chat ~p", [Info]),
    Reply = #{type => <<"reply">>, reply => ecai_chat:get_reply(SessionId, AeAccount, Chat)},
    {reply, {text, jsx:encode(Reply)}, State}.

test() ->
    ok.
