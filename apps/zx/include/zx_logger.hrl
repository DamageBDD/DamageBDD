-export([log/2, tell/1, tell/2]).


-spec log(Level, Format) -> ok
    when Level  :: info
                 | warning
                 | error,
         Format :: string().
%% @private
%% @equiv log(Level, Format, [])

log(Level, Format) ->
    log(Level, Format, []).


-spec log(Level, Format, Args) -> ok
    when Level  :: logger:level(),
         Format :: string(),
         Args   :: [term()].
%% @private
%% A logging abstraction to hide whatever logging back end is actually in use.
%% Format must adhere to Erlang format string rules, and the arity of Args must match
%% the provided format.

log(Level, Format, Args) ->
    Raw = io_lib:format("~w ~w: " ++ Format, [?MODULE, self() | Args]),
    Entry = unicode:characters_to_list(Raw),
    logger:log(Level, Entry).


-spec tell(Message) -> ok
    when Message :: string().

tell(Message) ->
    tell(Message, []).


tell(Format, Args) when is_list(Format) ->
    tell(info, Format, Args);
tell(Level, Message) when is_atom(Level) ->
    tell(Level, Message, []).


-spec tell(Level, Format, Args) -> ok
    when Level  :: logger:level(),
         Format :: string(),
         Args   :: [term()].

tell(Level, Format, Args) ->
    ok = log(Level, Format, Args),
    Out = io_lib:format(Format, Args),
    Message = unicode:characters_to_list([Out, "\n"]),
    io:put_chars(Message).


%-spec show(Parent, Format, Args) -> ok
%    when Parent :: wx:frame(),
%         Format :: string(),
%         Args   :: [term()].
%
% TODO: Convenience log + info/error modal for WX
%
%show(Parent, Format, Args) ->
