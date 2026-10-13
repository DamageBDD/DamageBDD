%%% @doc
%%% ZX TTY
%%%
%%% This module lets other parts of ZX interact (clumsily) with the user via a text
%%% interface. Hopefully this will never be called on Windows.
%%% @end

-module(zx_tty).
-vsn("0.14.0").
-author("Craig Everett <zxq9@zxq9.com>").
-copyright("Craig Everett <zxq9@zxq9.com>").
-license("GPL-3.0").

-export([get_input/0, get_input/1, get_input/2, get_input/3,
         get_lower0_9/1, get_lower0_9/2, get_lower0_9/3,
         select/1, select_string/1,
         dl/0, dl/2,
         derp/0]).


%%% Type Definitions

-type option() :: {string(), term()}.


%%% User menu interface (terminal)


-spec get_input() -> string().
%% @private
%% Provide a standard input prompt and newline sanitized return value.

get_input() ->
    case string:trim(io:get_line("(or \"QUIT\"): ")) of
        "QUIT" -> what_a_quitter();
        String -> String
    end.


-spec get_input(Info :: string()) -> string().
%% @private
%% Prompt the user for input.

get_input(Info) ->
    get_input(Info, []).


-spec get_input(Format, Args) -> string()
    when Format :: string(),
         Args   :: [term()].
%% @private
%% Allow the caller to use io format strings and args to create a prompt.


get_input(Format, Args) ->
    get_input(Format, Args, []).


-spec get_input(Format, Args, Prompt) -> string()
    when Format :: string(),
         Args   :: [term()],
         Prompt :: string().
%% @private
%% Similar to get_input/2, but allows a default prompt to be inserted after the
%% "QUIT" message (useful for things like bracketed default values).

get_input(Format, Args, Prompt) ->
    Info = io_lib:format(Format, Args),
    case string:trim(io:get_line([Info, "(or \"QUIT\") ", Prompt, ": "])) of
        "QUIT" -> what_a_quitter();
        String -> String
    end.


-spec get_lower0_9(Prompt :: string()) -> zx:lower0_9().
%% @private
%% Prompt the user for input, constraining the input to valid zx:lower0_9 strings.

get_lower0_9(Prompt) ->
    get_lower0_9(Prompt, []).


-spec get_lower0_9(Format, Args) -> zx:lower0_9()
    when Format :: string(),
         Args   :: [term()].

get_lower0_9(Format, Args) ->
    get_lower0_9(Format, Args, "").


get_lower0_9(Format, Args, Prompt) ->
    String = get_input(Format, Args, Prompt),
    case zx_lib:valid_lower0_9(String) of
        true ->
            String;
        false ->
            Message = "The string \"~ts\" isn't valid. Try \"[a-z0-9_]*\".~n",
            ok = io:format(Message, [String]),
            get_lower0_9(Format, Args, Prompt)
    end.


-spec select(Options) -> Selected
    when Options  :: [option()],
         Selected :: term().
%% @private
%% Take a list of Options to present the user, then return the indicated option to the
%% caller once the user selects something.

select(Options) ->
    Max = show(Options),
    case string:trim(io:get_line("(or \"QUIT\"): ")) of
        "QUIT" ->
            what_a_quitter();
        String ->
            case pick(string:to_integer(String), Max) of
                error ->
                    ok = hurr(),
                    select(Options);
                Index ->
                    {_, Value} = lists:nth(Index, Options),
                    Value
            end
    end.


-spec select_string(Strings) -> Selected
    when Strings  :: [string()],
         Selected :: string().
%% @private
%% @equiv select([{S, S} || S <- Strings])

select_string(Strings) ->
    select([{S, S} || S <- Strings]).


-spec show(Options) -> Index
    when Options :: [option()],
         Index   :: pos_integer().
%% @private
%% @equiv show(Options, 0).

show(Options) ->
    show(Options, 0).


-spec show(Options, Index) -> Count
    when Options :: [option()],
         Index   :: non_neg_integer(),
         Count   :: pos_integer().
%% @private
%% Display the list of options needed to the user, and return the option total count.

show([], I) ->
    I;
show([{Label, _} | Rest], I) ->
    Z = I + 1,
    ok = io:format("[~2w] ~ts~n", [Z, Label]),
    show(Rest, Z).


-spec pick({Selection, term()}, Max) -> Result
    when Selection :: error | integer(),
         Max       :: pos_integer(),
         Result    :: pos_integer() | error.
%% @private
%% Interpret a user's selection returning either a valid selection index or `error'.

pick({error, _}, _)                    -> error;
pick({I, _}, Max) when 0 < I, I =< Max -> I;
pick(_, _)                             -> error.


-spec dl(Size, Received) -> ok
    when Size     :: pos_integer(),
         Received :: non_neg_integer().

dl() ->
    io:format("~n[  0.00%]").

dl(Size, Size) ->
    io:format("\r[~6.2f%]~n", [100.0]);
dl(Size, Received) ->
    P = (Received * 100) / Size,
    io:format("\r[~6.2f%]", [P]).


-spec hurr() -> ok.
%% @private
%% Present an appropriate response when the user derps on selection.

hurr() -> io:format("That isn't an option.~n").


-spec what_a_quitter() -> no_return().
%% @private
%% Halt the runtime if the user decides to quit.

what_a_quitter() ->
    ok = io:format("User abort: \"QUIT\".~nHalting.~n"),
    ok = init:stop(),
    receive Message -> io:format("Death Note: ~tp~n", [Message]) end.


-spec derp() -> ok.

derp() ->
    io:format("~nArglebargle, glop-glyf!?!~n~n").
