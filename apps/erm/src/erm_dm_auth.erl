%%%-------------------------------------------------------------------
%%% Authentication state machine.
%%%
%%% Credentials never enter this process. The native helper owns GREETD_SOCK,
%%% PAM conversations and GtkPasswordEntry/GtkEntry prompt buffers. Erlang sends
%%% only username + opaque session id and receives sanitized state events.
%%%-------------------------------------------------------------------
-module(erm_dm_auth).
-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

-export([start_link/0, status/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {user = undefined, session = undefined, phase = idle,
                port = undefined, started_at = undefined, last_error = undefined}).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
status() -> gen_server:call(?MODULE, status).

init([]) -> process_flag(trap_exit, true), {ok, #state{}}.

handle_call(status, _From, S) -> {reply, public_status(S), S};
handle_call({select_user, User0}, _From, S = #state{phase = idle}) ->
    User = to_bin(User0),
    case erm_dm_users:lookup(User) of
        {ok, _} -> {reply, ok, S#state{user = User, last_error = undefined}};
        Error -> {reply, Error, S}
    end;
handle_call({select_session, Id0}, _From, S = #state{phase = idle}) ->
    Id = to_bin(Id0),
    case erm_dm_sessions:lookup(Id) of
        {ok, _} -> {reply, ok, S#state{session = Id, last_error = undefined}};
        Error -> {reply, Error, S}
    end;
handle_call(login, _From, S = #state{phase = idle, user = U, session = Session})
  when is_binary(U), is_binary(Session) ->
    case start_helper(U, Session) of
        {ok, Port} ->
            {reply, {ok, authenticating}, S#state{phase = authenticating, port = Port,
                                                  started_at = erlang:monotonic_time(millisecond),
                                                  last_error = undefined}};
        Error -> {reply, Error, S#state{last_error = sanitize(Error)}}
    end;
handle_call(login, _From, S = #state{phase = idle}) -> {reply, {error, selection_incomplete}, S};
handle_call(login, _From, S) -> {reply, {error, busy}, S};
handle_call(cancel, _From, S) -> {reply, ok, cancel_helper(S)};
handle_call(_, _, S) -> {reply, {error, unsupported_call}, S}.

handle_cast(_, S) -> {noreply, S}.

handle_info({Port, {data, {eol, Data}}}, S = #state{port = Port}) ->
    {noreply, helper_event(Data, S)};
handle_info({Port, {data, {noeol, _Data}}}, S = #state{port = Port}) ->
    %% The native protocol only emits short fixed tokens. Overlong lines are
    %% discarded rather than accumulated into OTP state.
    {noreply, S};
handle_info({Port, {exit_status, Status}}, S = #state{port = Port, phase = Phase}) ->
    case {Status, Phase} of
        {0, accepted} -> {noreply, S#state{port = undefined}};
        {0, _} -> {noreply, S#state{phase = idle, port = undefined}};
        _ -> {noreply, S#state{phase = idle, port = undefined, last_error = {helper_exit, Status}}}
    end;
handle_info({'EXIT', Port, Reason}, S = #state{port = Port}) ->
    {noreply, S#state{phase = idle, port = undefined, last_error = sanitize(Reason)}};
handle_info(stop_greeter, S = #state{phase = accepted}) ->
    Config = application:get_env(erm, display_manager, []),
    case proplists:get_value(exit_on_accept, Config, true) of
        true -> spawn(fun() -> timer:sleep(25), init:stop(0) end);
        false -> ok
    end,
    {noreply, S};
handle_info(_, S) -> {noreply, S}.

terminate(_, S) -> _ = cancel_helper(S), ok.
code_change(_, S, _) -> {ok, S}.

start_helper(User, SessionId) ->
    Config = application:get_env(erm, display_manager, []),
    Helper0 = proplists:get_value(auth_helper, Config, default_helper()),
    Helper = path(Helper0),
    case filelib:is_regular(Helper) of
        false -> {error, {auth_helper_missing, Helper}};
        true ->
            Env = sanitized_env(["GREETD_SOCK", "DISPLAY", "XAUTHORITY", "XDG_RUNTIME_DIR"]),
            Port = open_port({spawn_executable, Helper}, [binary, exit_status, stderr_to_stdout, {line, 512},
                {args, [binary_to_list(User), binary_to_list(SessionId)]}, {env, Env}]),
            {ok, Port}
    end.

default_helper() ->
    case code:priv_dir(erm) of
        {error, _} -> "apps/erm/priv/erm_greetd_auth";
        Dir -> filename:join(Dir, "erm_greetd_auth")
    end.

helper_event(<<"state:prompt">>, S) -> publish(prompt), S#state{phase = prompting};
helper_event(<<"state:authenticating">>, S) -> publish(authenticating), S#state{phase = authenticating};
helper_event(<<"state:accepted">>, S) ->
    publish(accepted),
    erlang:send_after(100, self(), stop_greeter),
    S#state{phase = accepted};
helper_event(<<"state:cancelled">>, S) -> publish(cancelled), S#state{phase = idle, port = undefined};
helper_event(<<"error:auth_failed">>, S) -> publish(auth_failed), S#state{phase = idle, last_error = auth_failed};
helper_event(<<"error:", Rest/binary>>, S) ->
    Err = {auth_helper, safe_token(Rest)}, publish(Err), S#state{phase = idle, last_error = Err};
helper_event(_Unknown, S) -> S.

cancel_helper(S = #state{port = undefined}) -> S#state{phase = idle};
cancel_helper(S = #state{port = Port}) ->
    catch port_command(Port, <<"cancel\n">>),
    catch port_close(Port),
    S#state{phase = idle, port = undefined}.

public_status(S) -> #{user => S#state.user, session => S#state.session,
                      phase => S#state.phase, last_error => S#state.last_error,
                      helper_alive => is_port(S#state.port)}.

publish(Event) ->
    case whereis(erm_dm_ui) of undefined -> ok; Pid -> Pid ! {erm_dm_auth, Event} end.

sanitized_env(Names) ->
    [{N, case os:getenv(N) of false -> false; V -> V end} || N <- Names].

safe_token(B) ->
    << <<C>> || <<C>> <= B, (C >= $a andalso C =< $z) orelse C =:= $_ orelse C =:= $- >>.
sanitize({auth_helper_missing, _} = E) -> E;
sanitize(_) -> internal_error.
path(B) when is_binary(B) -> binary_to_list(B);
path(L) when is_list(L) -> L.
to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> unicode:characters_to_binary(L).
