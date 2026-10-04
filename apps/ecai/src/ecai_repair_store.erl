-module(ecai_repair_store).

%% Crash-safe, content-addressed persistence for capsules and verification events.
-export([
    default_root/0,
    persist_capsule/1,
    persist_capsule/2,
    load_capsule/2,
    persist_event/3,
    read_term/1
]).

-spec default_root() -> file:filename().
default_root() ->
    case application:get_env(ecai, state_root) of
        {ok, Root} -> filename:join(to_list(Root), "repair_invariants");
        _ -> filename:join([default_data_root(), "ecai", "repair_invariants"])
    end.

-spec persist_capsule(map()) -> {ok, binary()} | {error, term()}.
persist_capsule(Capsule) -> persist_capsule(default_root(), Capsule).

-spec persist_capsule(file:filename_all(), map()) -> {ok, binary()} | {error, term()}.
persist_capsule(Root0, Capsule) ->
    case ecai_repair_capsule:validate(Capsule) of
        ok ->
            Root = to_list(Root0),
            Id = binary_to_list(ecai_repair_capsule:id(Capsule)),
            Path = filename:join([Root, "capsules", Id ++ ".term"]),
            case write_term(Path, Capsule) of
                ok -> {ok, unicode:characters_to_binary(Path)};
                Error -> Error
            end;
        Error ->
            Error
    end.

-spec load_capsule(file:filename_all(), binary() | list()) -> {ok, map()} | {error, term()}.
load_capsule(Root0, Id0) ->
    Path = filename:join([to_list(Root0), "capsules", to_list(Id0) ++ ".term"]),
    case read_term(Path) of
        {ok, Capsule} ->
            case ecai_repair_capsule:validate(Capsule) of
                ok -> {ok, Capsule};
                Error -> Error
            end;
        Error ->
            Error
    end.

-spec persist_event(file:filename_all(), binary() | list(), map()) ->
    {ok, binary()} | {error, term()}.
persist_event(Root0, Family0, Event) ->
    Root = to_list(Root0),
    Family = safe_component(to_list(Family0)),
    Unique = integer_to_list(erlang:unique_integer([positive, monotonic])),
    Time = integer_to_list(erlang:system_time(millisecond)),
    Path = filename:join([Root, "events", Family, Time ++ "-" ++ Unique ++ ".term"]),
    case write_term(Path, Event) of
        ok -> {ok, unicode:characters_to_binary(Path)};
        Error -> Error
    end.

-spec read_term(file:filename_all()) -> {ok, term()} | {error, term()}.
read_term(Path0) ->
    case file:read_file(to_list(Path0)) of
        {ok, Bin} ->
            try
                {ok, binary_to_term(Bin, [safe])}
            catch
                Class:Reason -> {error, {invalid_term_file, Class, Reason}}
            end;
        Error ->
            Error
    end.

write_term(Path, Term) ->
    ok = filelib:ensure_dir(Path),
    Tmp = Path ++ ".tmp." ++ integer_to_list(erlang:unique_integer([positive, monotonic])),
    Bin = term_to_binary(Term, [compressed]),
    case file:open(Tmp, [write, raw, binary, exclusive]) of
        {ok, Io} ->
            Result =
                case file:write(Io, Bin) of
                    ok -> file:sync(Io);
                    Error -> Error
                end,
            Close = file:close(Io),
            case {Result, Close} of
                {ok, ok} ->
                    case file:rename(Tmp, Path) of
                        ok ->
                            ok;
                        {error, eexist} ->
                            file:delete(Tmp),
                            ok;
                        Error0 ->
                            file:delete(Tmp),
                            Error0
                    end;
                {Error1, _} ->
                    file:delete(Tmp),
                    Error1
            end;
        {error, eexist} ->
            write_term(Path, Term);
        Error ->
            Error
    end.

default_data_root() ->
    case os:getenv("XDG_STATE_HOME") of
        false ->
            case os:getenv("HOME") of
                false -> "/tmp";
                Home -> filename:join(Home, ".local/state")
            end;
        Root ->
            Root
    end.

safe_component(Value) ->
    [
        case
            (C >= $a andalso C =< $z) orelse (C >= $A andalso C =< $Z) orelse
                (C >= $0 andalso C =< $9) orelse C =:= $- orelse C =:= $_
        of
            true -> C;
            false -> $_
        end
     || C <- Value
    ].

to_list(Value) when is_list(Value) -> Value;
to_list(Value) when is_binary(Value) -> unicode:characters_to_list(Value).
