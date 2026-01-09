-module(damage_step_tokenizer).

-export([tokenize/1]).

%% Tokenizer that:
%% - Keeps quoted strings intact (as a single token, without quotes)
%% - Splits numeric tokens: 390, 1, -2, 1.5, .5
%% - Splits arg-words like center/left/right/top/bottom into their own tokens
%% - Preserves everything else as larger phrase chunks to keep step matching stable

tokenize(Step) when is_binary(Step) ->
    tokenize(binary_to_list(Step));
tokenize(Step) when is_list(Step) ->
    Tokens0 = tokenize_scan(Step, outside, [], []),
    [strip(T) || T <- Tokens0, strip(T) =/= ""].

%% -------------------------------------------------------------------
%% scanner
%% -------------------------------------------------------------------

%% State = outside | in_quote
%% Acc   = current outside token buffer (reversed charlist)
%% Out   = tokens (reversed list of strings)

tokenize_scan([], _State, Acc, Out) ->
    lists:reverse(flush_acc(Acc, Out));
tokenize_scan([$" | Rest], outside, Acc, Out) ->
    %% Enter quote: flush accumulated outside text first
    tokenize_scan(Rest, in_quote, [], flush_acc(Acc, Out));
tokenize_scan([$" | Rest], in_quote, Acc, Out) ->
    %% Exit quote: push quoted token as-is (no strip inside quotes)
    tokenize_scan(Rest, outside, [], [lists:reverse(Acc) | Out]);
tokenize_scan([C | Rest], in_quote, Acc, Out) ->
    tokenize_scan(Rest, in_quote, [C | Acc], Out);
tokenize_scan([C | Rest], outside, Acc, Out) ->
    case is_num_start(C, Rest) of
        true ->
            Out1 = flush_acc(Acc, Out),
            {NumTok, Rest1} = read_number([C | Rest]),
            tokenize_scan(Rest1, outside, [], [NumTok | Out1]);
        false ->
            %% fallthrough to arg-word / normal char handling
            tokenize_scan_outside_nonnum([C | Rest], Acc, Out)
    end.

tokenize_scan_outside_nonnum(Rest, Acc, Out) ->
    case read_arg_word(Rest) of
        {none} ->
            [C | Rest1] = Rest,
            tokenize_scan(Rest1, outside, [C | Acc], Out);
        {arg, ArgWord, Rest1, true} ->
            Out1 = flush_acc(Acc, Out),
            tokenize_scan(Rest1, outside, [], [ArgWord | Out1]);
        {arg, _ArgWord, _Rest1, false} ->
            [C | Rest1] = Rest,
            tokenize_scan(Rest1, outside, [C | Acc], Out)
    end.

%% -------------------------------------------------------------------
%% helpers
%% -------------------------------------------------------------------

flush_acc([], Out) ->
    Out;
flush_acc(Acc, Out) ->
    Tok = strip(lists:reverse(Acc)),
    case Tok of
        "" -> Out;
        _ -> [Tok | Out]
    end.

strip(S) ->
    string:strip(S).

%% Start of numeric:
%% - digit
%% - '-' followed by digit
%% - '.' followed by digit (allows .5)
is_num_start($-, [Nxt | _]) -> is_digit(Nxt);
is_num_start($., [Nxt | _]) -> is_digit(Nxt);
is_num_start(C, _) -> is_digit(C).

is_digit(C) -> C >= $0 andalso C =< $9.

%% Reads a number like: 390, 1.0, -2, .5
read_number(Cs) ->
    read_number(Cs, []).

read_number([], Acc) ->
    {lists:reverse(Acc), []};
read_number([C | Rest], Acc) ->
    case ((C >= $0 andalso C =< $9) orelse C =:= $. orelse C =:= $-) of
        true -> read_number(Rest, [C | Acc]);
        false -> {lists:reverse(Acc), [C | Rest]}
    end.

%% -------------------------------------------------------------------
%% arg-word splitting (non-numeric params)
%% -------------------------------------------------------------------

arg_words() ->
    %% Keep this list small and “argument-like” to avoid breaking phrase chunks
    ["left", "right", "center", "top", "bottom", "middle", "start", "end"].

read_arg_word(Rest = [C | _]) ->
    case is_alpha(C) of
        true -> try_match_arg_words(Rest, arg_words());
        false -> {none}
    end;
read_arg_word([]) ->
    {none}.

try_match_arg_words(_Rest, []) ->
    {none};
try_match_arg_words(Rest, [W | Ws]) ->
    case prefix_ci(Rest, W) of
        {true, RestAfter} ->
            %% ensure next char is a boundary (or end)
            case RestAfter of
                [] ->
                    {arg, W, RestAfter, true};
                [Next | _] ->
                    case is_boundary(Next) of
                        true -> {arg, W, RestAfter, true};
                        false -> try_match_arg_words(Rest, Ws)
                    end
            end;
        false ->
            try_match_arg_words(Rest, Ws)
    end.

prefix_ci(Rest, Word) ->
    WL = length(Word),
    case length(Rest) >= WL of
        false ->
            false;
        true ->
            Prefix = lists:sublist(Rest, WL),
            case string:to_lower(Prefix) =:= Word of
                true -> {true, lists:nthtail(WL, Rest)};
                false -> false
            end
    end.

is_alpha(C) ->
    (C >= $a andalso C =< $z) orelse (C >= $A andalso C =< $Z).

is_boundary(C) ->
    C =:= $\s orelse C =:= $\t orelse C =:= $\n orelse
        C =:= $. orelse C =:= $, orelse C =:= $: orelse
        C =:= $; orelse C =:= $( orelse C =:= $) orelse
        C =:= $[ orelse C =:= $] orelse C =:= ${ orelse
        C =:= $} orelse C =:= $/ orelse C =:= $\\ orelse
        C =:= $= orelse C =:= $+ orelse C =:= $- orelse
        C =:= $* orelse C =:= $? orelse C =:= $! orelse
        C =:= $< orelse C =:= $>.
