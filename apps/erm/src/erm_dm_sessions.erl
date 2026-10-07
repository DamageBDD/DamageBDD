%%%-------------------------------------------------------------------
%%% Root-owned session catalog. No shell command is accepted from the UI.
%%%-------------------------------------------------------------------
-module(erm_dm_sessions).
-behaviour(gen_server).

-export([start_link/0, list/0, lookup/1, reload/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
list() -> gen_server:call(?MODULE, list).
lookup(Id) -> gen_server:call(?MODULE, {lookup, to_bin(Id)}).
reload() -> gen_server:call(?MODULE, reload).

init([]) -> {ok, load()}.
handle_call(list, _From, S) -> {reply, {ok, public_sessions(S)}, S};
handle_call({lookup, Id}, _From, S) -> {reply, lookup_map(Id, S), S};
handle_call(reload, _From, _S) -> S = load(), {reply, ok, S};
handle_call(_, _, S) -> {reply, {error, unsupported_call}, S}.
handle_cast(_, S) -> {noreply, S}.
handle_info(_, S) -> {noreply, S}.
terminate(_, _) -> ok.
code_change(_, S, _) -> {ok, S}.

load() ->
    Config = application:get_env(erm, display_manager, []),
    Raw = proplists:get_value(sessions, Config, default_sessions()),
    maps:from_list([normalize(E) || E <- Raw]).

default_sessions() ->
    [[{id, "herbstluftwm"},
      {label, "herbstluftwm"},
      {command, "/usr/bin/herbstluftwm"},
      {args, []},
      {desktop, "herbstluftwm"}]].

normalize(Props) ->
    Id = to_bin(proplists:get_value(id, Props)),
    Cmd = to_bin(proplists:get_value(command, Props)),
    true = valid_id(Id),
    true = absolute(Cmd),
    Label = to_bin(proplists:get_value(label, Props, Id)),
    Args = [to_bin(A) || A <- proplists:get_value(args, Props, [])],
    Desktop = to_bin(proplists:get_value(desktop, Props, Id)),
    {Id, #{id => Id, label => Label, command => Cmd, args => Args, desktop => Desktop}}.

public_sessions(S) -> [maps:with([id, label, desktop], V) || {_K, V} <- lists:sort(maps:to_list(S))].
lookup_map(Id, S) -> case maps:find(Id, S) of {ok, V} -> {ok, V}; error -> {error, unknown_session} end.
valid_id(Id) when is_binary(Id), byte_size(Id) > 0, byte_size(Id) =< 64 ->
    lists:all(fun(C) -> (C >= $a andalso C =< $z) orelse (C >= $A andalso C =< $Z) orelse
                        (C >= $0 andalso C =< $9) orelse C =:= $_ orelse C =:= $- end,
              binary_to_list(Id));
valid_id(_) -> false.
absolute(<<$/, _/binary>>) -> true;
absolute(_) -> false.
to_bin(B) when is_binary(B) -> B;
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_bin(L) when is_list(L) -> unicode:characters_to_binary(L).
