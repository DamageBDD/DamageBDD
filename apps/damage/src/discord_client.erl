%%--------------------------------------------------------------------
%% discord_client.erl
%%
%% Simple Discord client that maintains a gun TLS connection and
%% can post messages to channels.
%%
%% Usage:
%%   1) Configure (optional):
%%        application:set_env(damage, discord_bot_token, "YOUR_BOT_TOKEN").
%%        application:set_env(damage, discord_default_channel, "123456789012345678").
%%
%%   2) Start:
%%        discord_client:start_link().
%%
%%   3) Post (async):
%%        discord_client:send_message("123456789012345678", <<"hello world">>).
%%
%%      Or use default_channel from env / init options:
%%        discord_client:send_message(<<"hello world via default channel">>).
%%--------------------------------------------------------------------
-module(discord_client).

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

%% API
-export([
    start_link/0,
    start_link/1,
    send_message/1,
    send_message/2,
    send_message_sync/1,
    send_message_sync/2
]).

%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(DEFAULT_HOST, "discord.com").
-define(DEFAULT_PORT, 443).
-define(DEFAULT_TIMEOUT, 30000).

-record(state, {
    host :: string(),
    port :: non_neg_integer(),
    token :: binary(),
    default_channel :: binary() | undefined,
    conn_pid :: pid() | undefined,
    conn_ref :: reference() | undefined
}).

%%%===================================================================
%%% Public API
%%%===================================================================

start_link() ->
    start_link(#{}).

%% Opts map keys:
%%   - host            :: string() (default "discord.com")
%%   - port            :: integer() (default 443)
%%   - token           :: binary() | string() (Bot token)
%%   - default_channel :: binary() | string()
start_link(Opts) when is_map(Opts) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Opts, []).

%% Async send using default_channel from state/env
-spec send_message(binary() | string()) -> ok.
send_message(Content) ->
    gen_server:cast(?MODULE, {send_default, Content}).

%% Async send to specific channel
-spec send_message(binary() | string(), binary() | string()) -> ok.
send_message(ChannelId, Content) ->
    gen_server:cast(?MODULE, {send, ChannelId, Content}).

%% Sync send using default_channel
-spec send_message_sync(binary() | string()) ->
    {ok, map()} | {error, term()}.
send_message_sync(Content) ->
    gen_server:call(?MODULE, {send_default, Content}, ?DEFAULT_TIMEOUT).

%% Sync send to specific channel
-spec send_message_sync(binary() | string(), binary() | string()) ->
    {ok, map()} | {error, term()}.
send_message_sync(ChannelId, Content) ->
    gen_server:call(?MODULE, {send, ChannelId, Content}, ?DEFAULT_TIMEOUT).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init(Opts0) ->
    process_flag(trap_exit, true),

    Host = maps:get(host, Opts0, ?DEFAULT_HOST),
    Port = maps:get(port, Opts0, ?DEFAULT_PORT),

    Token0 =
        case maps:get(token, Opts0, undefined) of
            undefined ->
                case application:get_env(damage, discord_bot_token) of
                    {ok, T} ->
                        T;
                    _ ->
                        ?LOG_ERROR("Discord bot token not configured.", []),
                        erlang:error(missing_discord_bot_token)
                end;
            T ->
                T
        end,
    Token = to_bin(Token0),

    DefaultChannel0 =
        case maps:get(default_channel, Opts0, undefined) of
            undefined ->
                case application:get_env(damage, discord_default_channel) of
                    {ok, C} -> C;
                    _ -> undefined
                end;
            C ->
                C
        end,
    DefaultChannel =
        case DefaultChannel0 of
            undefined -> undefined;
            _ -> to_bin(DefaultChannel0)
        end,

    State0 = #state{
        host = Host,
        port = Port,
        token = Token,
        default_channel = DefaultChannel,
        conn_pid = undefined,
        conn_ref = undefined
    },

    {ok, State1} = ensure_connection(State0),
    {ok, State1}.

handle_call({send_default, Content0}, _From, State0) ->
    case State0#state.default_channel of
        undefined ->
            {reply, {error, no_default_channel}, State0};
        ChannelId ->
            handle_call({send, ChannelId, Content0}, _From, State0)
    end;
handle_call({send, ChannelId0, Content0}, _From, State0) ->
    ChannelId = to_bin(ChannelId0),
    Content = to_bin(Content0),
    case ensure_connection(State0) of
        {ok, State1} ->
            case do_post_message(State1, ChannelId, Content) of
                {ok, RespMap, State2} ->
                    {reply, {ok, RespMap}, State2};
                {error, Reason, State2} ->
                    {reply, {error, Reason}, State2}
            end;
        {error, Reason, State1} ->
            {reply, {error, Reason}, State1}
    end;
handle_call(_Req, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast({send_default, Content0}, State0) ->
    case State0#state.default_channel of
        undefined ->
            ?LOG_WARNING("Discord default channel not configured; dropping message.", []),
            {noreply, State0};
        ChannelId ->
            handle_cast({send, ChannelId, Content0}, State0)
    end;
handle_cast({send, ChannelId0, Content0}, State0) ->
    ChannelId = to_bin(ChannelId0),
    Content = to_bin(Content0),
    case ensure_connection(State0) of
        {ok, State1} ->
            _ = do_post_message(State1, ChannelId, Content),
            {noreply, State1};
        {error, Reason, State1} ->
            ?LOG_WARNING("Discord send failed to ensure connection: ~p", [Reason]),
            {noreply, State1}
    end;
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(
    {'DOWN', Ref, process, Pid, Reason},
    #state{conn_pid = Pid, conn_ref = Ref} = State
) ->
    ?LOG_WARNING("Discord connection down: ~p", [Reason]),
    %% Clear conn and try reconnect lazily on next send
    {noreply, State#state{conn_pid = undefined, conn_ref = undefined}};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(Reason, _State) ->
    ?LOG_INFO("discord_client terminating (~p)", [Reason]),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal helpers
%%%===================================================================

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> list_to_binary(L);
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8).

-spec ensure_connection(#state{}) -> {ok, #state{}} | {error, term(), #state{}}.
ensure_connection(#state{conn_pid = Pid} = State) when is_pid(Pid) ->
    case is_process_alive(Pid) of
        true -> {ok, State};
        false -> open_connection(State#state{conn_pid = undefined, conn_ref = undefined})
    end;
ensure_connection(State) ->
    open_connection(State).

open_connection(#state{host = Host, port = Port} = State) ->
    Opts = #{transport => tls, tls_opts => [{verify, verify_none}]},
    ?LOG_DEBUG("Opening Discord gun connection ~p:~p", [Host, Port]),
    case gun:open(Host, Port, Opts) of
        {ok, ConnPid} ->
            Ref = erlang:monitor(process, ConnPid),
            {ok, State#state{conn_pid = ConnPid, conn_ref = Ref}};
        Error ->
            ?LOG_ERROR("Failed to open Discord connection: ~p", [Error]),
            {error, Error, State}
    end.

%% Core POST /api/v10/channels/{channel_id}/messages
-spec do_post_message(#state{}, binary(), binary()) ->
    {ok, map(), #state{}} | {error, term(), #state{}}.
do_post_message(
    #state{
        conn_pid = ConnPid,
        token = Token,
        host = Host
    } = State,
    ChannelId,
    Content
) when is_pid(ConnPid) ->
    Path = ["/api/v10/channels/", ChannelId, "/messages"],
    Headers =
        [
            {<<"host">>, to_bin(Host)},
            {<<"user-agent">>, <<"damagebdd-discord/0.1.0">>},
            {<<"authorization">>, [<<"Bot ">>, Token]},
            {<<"content-type">>, <<"application/json">>}
        ],
    BodyBin = jsx:encode(#{content => Content}),

    ?LOG_DEBUG("Discord POST ~p", [Path]),

    StreamRef = gun:post(ConnPid, Path, Headers, BodyBin),
    case gun:await(ConnPid, StreamRef, ?DEFAULT_TIMEOUT) of
        {response, fin, Status, RespHeaders} ->
            %% No body – Discord usually sends a JSON body, but handle this just in case
            ?LOG_DEBUG("Discord response (fin) ~p ~p", [Status, RespHeaders]),
            {ok, #{status => Status, headers => RespHeaders}, State};
        {response, nofin, Status, RespHeaders} ->
            case gun:await_body(ConnPid, StreamRef) of
                {ok, RespBody} ->
                    RespMap =
                        case catch jsx:decode(RespBody, [{labels, atom}, return_maps]) of
                            {'EXIT', _} -> #{raw => RespBody};
                            Decoded -> Decoded
                        end,
                    ?LOG_DEBUG("Discord response ~p", [Status]),
                    {ok,
                        RespMap#{
                            status => Status,
                            headers => RespHeaders
                        },
                        State};
                BodyError ->
                    {error, {body_error, BodyError}, State}
            end;
        Other ->
            ?LOG_ERROR("Discord unexpected gun response ~p", [Other]),
            {error, Other, State}
    end;
do_post_message(State, _ChannelId, _Content) ->
    {error, no_connection, State}.
