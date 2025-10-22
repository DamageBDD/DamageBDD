%%--------------------------------------------------------------------
%% steps_selinux.erl — BDD steps for SELinux (no shell, user-generic)
%%--------------------------------------------------------------------
-module(steps_selinux).
-author("Steven Joseph <steven@stevenjoseph.in>").

-include_lib("kernel/include/logger.hrl").

-export([step/6]).

%% ===== Records (must be defined before use) =======================
-record(p, {pid :: integer(), user :: string(), comm :: string(), ctx :: string()}).

%% ===== Steps =======================================================

%% When I query selinux status
step(
    _Config,
    #{public_key := AeAccount} = Ctx,
    <<"When">>,
    _N,
    [<<"I query selinux status">>],
    _Extra
) ->
    true = steps_utils:is_admin(AeAccount),
    case run_bin("getenforce", []) of
        {ok, Out, Err} ->
            put_last(Ctx, ["getenforce"], Out, Err),
            maps:put(selinux_status_raw, Out, Ctx);
        {error, _} ->
            case run_bin("sestatus", []) of
                {ok, Out, Err} ->
                    put_last(Ctx, ["sestatus"], Out, Err),
                    maps:put(selinux_status_raw, Out, Ctx);
                Err2 ->
                    maps:put(fail, io_lib:format("Failed to query SELinux: ~p", [Err2]), Ctx)
            end
    end;
%% Then selinux status must be "Enforcing"
step(
    _Config,
    #{public_key := AeAccount} = Ctx,
    <<"Then">>,
    _N,
    [<<"selinux status must be">>, Expected],
    _Extra
) ->
    true = steps_utils:is_admin(AeAccount),
    StatusRaw =
        case maps:get(selinux_status_raw, Ctx, undefined) of
            undefined ->
                case run_bin("getenforce", []) of
                    {ok, Out, Err} ->
                        put_last(Ctx, ["getenforce"], Out, Err),
                        Out;
                    _ ->
                        <<"">>
                end;
            V ->
                V
        end,
    Status = string:trim(to_list(StatusRaw)),
    Exp = to_list(Expected),
    case Status of
        _ when Status =:= Exp ->
            Ctx;
        _ ->
            maps:put(fail, io_lib:format("Expected ~s, got ~s", [Exp, Status]), Ctx)
    end;
%% When I collect process selinux labels
step(
    _Config,
    #{public_key := AeAccount} = Ctx,
    <<"When">>,
    _N,
    [<<"I collect process selinux labels">>],
    _Extra
) ->
    true = steps_utils:is_admin(AeAccount),
    case run_bin("ps", ["-eZ", "-o", "pid=,user=,comm="]) of
        {ok, Out, Err} ->
            put_last(Ctx, ["ps", "-eZ", "-o", "pid=,user=,comm="], Out, Err),
            Procs = parse_ps_eZ(Out),
            maps:put(selinux_procs, Procs, Ctx);
        {error, R} ->
            maps:put(fail, io_lib:format("Failed ps -eZ: ~p", [R]), Ctx)
    end;
%% Then processes of user "alice" must be in selinux domain containing "something_t"
step(
    _Config,
    #{public_key := AeAccount} = Ctx,
    <<"Then">>,
    _N,
    [<<"processes of user">>, User, <<"must be in selinux domain containing">>, Token],
    _Extra
) ->
    true = steps_utils:is_admin(AeAccount),
    Procs = ensure_procs(Ctx),
    LowerToken = string:to_lower(to_list(Token)),
    Matches = [
        P
     || P <- Procs,
        string:to_lower(P#p.user) =:= string:to_lower(to_list(User)),
        string:find(string:to_lower(P#p.ctx), LowerToken) =/= nomatch
    ],
    case Matches of
        [] ->
            maps:put(
                fail,
                io_lib:format("No processes for user ~s in domain containing ~s", [User, Token]),
                Ctx
            );
        _ ->
            maps:put(selinux_user_domain_matches, Matches, Ctx)
    end;
%% When I write a selinux policy template for "name" to "/tmp/name.te"
step(
    _Config,
    #{public_key := AeAccount} = Ctx,
    <<"When">>,
    _N,
    [<<"I write a selinux policy template for">>, Name, <<"to">>, Path],
    _Extra
) ->
    true = steps_utils:is_admin(AeAccount),
    Mod = sanitize_name(Name),
    Te = build_te(Mod),
    case file:write_file(to_list(Path), Te) of
        ok -> maps:put(selinux_te_written, #{name => Mod, path => Path}, Ctx);
        Err -> maps:put(fail, io_lib:format("Write TE failed: ~p", [Err]), Ctx)
    end;
%% When I build selinux module from te at "/tmp/name.te"
step(_Config, Ctx, <<"When">>, _N, [<<"I build selinux module from te at">>, TePath], _Extra) ->
    true = steps_utils:is_admin(Ctx),
    Base = filename:basename(to_list(TePath), ".te"),
    ModF = filename:join("/tmp", Base ++ ".mod"),
    PpF = filename:join("/tmp", Base ++ ".pp"),
    case run_bin("checkmodule", ["-M", "-m", "-o", ModF, to_list(TePath)]) of
        {ok, Out1, Err1} ->
            put_last(Ctx, ["checkmodule", "-M", "-m", "-o", ModF, to_list(TePath)], Out1, Err1),
            case run_bin("semodule_package", ["-o", PpF, "-m", ModF]) of
                {ok, Out2, Err2} ->
                    put_last(Ctx, ["semodule_package", "-o", PpF, "-m", ModF], Out2, Err2),
                    maps:put(selinux_module_build, #{mod => ModF, pp => PpF}, Ctx);
                E2 ->
                    maps:put(fail, io_lib:format("semodule_package failed: ~p", [E2]), Ctx)
            end;
        E1 ->
            maps:put(fail, io_lib:format("checkmodule failed: ~p", [E1]), Ctx)
    end;
%% Then user "alice" must have a process in domain "damage_t"
step(
    _Config,
    Ctx,
    <<"Then">>,
    _N,
    [<<"user">>, User, <<"must have a process in domain">>, ExactDom],
    _Extra
) ->
    true = steps_utils:is_admin(Ctx),
    Procs = ensure_procs(Ctx),
    Expected = string:to_lower(to_list(ExactDom)),
    HasAny = lists:any(
        fun(P) ->
            string:to_lower(P#p.user) =:= string:to_lower(to_list(User)) andalso
                string:to_lower(domain_from_ctx(P#p.ctx)) =:= Expected
        end,
        Procs
    ),
    case HasAny of
        true ->
            Ctx;
        false ->
            maps:put(
                fail, io_lib:format("No process of user ~s in domain ~s", [User, ExactDom]), Ctx
            )
    end;
%% Then the last selinux stdout must contain "text"
step(_Config, Ctx, <<"Then">>, _N, [<<"the last selinux stdout must contain">>, Sub], _Extra) ->
    true = steps_utils:is_admin(Ctx),
    case maps:get(selinux_last_run, Ctx, undefined) of
        #{stdout := Out} ->
            case string:find(string:to_lower(Out), string:to_lower(to_list(Sub))) of
                nomatch -> maps:put(fail, io_lib:format("Did not find ~p in stdout", [Sub]), Ctx);
                _ -> Ctx
            end;
        _ ->
            maps:put(fail, <<"No previous SELinux command captured">>, Ctx)
    end.

%% ===== Helpers =====================================================

%% Run a binary without shell; returns {ok, StdoutStr, StderrStr} | {error, Reason}
run_bin(Name, Args) ->
    case os:find_executable(Name) of
        false ->
            {error, {not_found, Name}};
        Path ->
            case exec:run([Path | [to_list(A) || A <- Args]], [sync, stdout, stderr]) of
                {ok, Parts} ->
                    Stdout = iolist_to_binary(proplists:get_value(stdout, Parts, <<>>)),
                    Stderr = iolist_to_binary(proplists:get_value(stderr, Parts, <<>>)),
                    {ok, binary_to_list(Stdout), binary_to_list(Stderr)};
                Err ->
                    Err
            end
    end.

put_last(Ctx, Cmd, Out, Err) ->
    maps:put(selinux_last_run, #{cmd => Cmd, stdout => Out, stderr => Err}, Ctx).

ensure_procs(Ctx) ->
    maps:get(
        selinux_procs,
        Ctx,
        case run_bin("ps", ["-eZ", "-o", "pid=,user=,comm="]) of
            {ok, Out, _} -> parse_ps_eZ(Out);
            _ -> []
        end
    ).

%% Parse `ps -eZ -o pid=,user=,comm=` lines.
parse_ps_eZ(Text) ->
    Lines = [L || L <- string:split(Text, "\n", all), L =/= ""],
    Parsed = [parse_ps_line(L) || L <- Lines],
    [P || P <- Parsed, is_record(P, p)].

%% Expect: "<ctx> <pid> <user> <comm ...>"
parse_ps_line(Line0) ->
    Line = string:trim(Line0),
    case take_token(Line) of
        {Ctx, R1} ->
            case scan_int(R1) of
                {Pid, R2} ->
                    case scan_word(R2) of
                        {User, Comm0} ->
                            Comm = string:trim(Comm0),
                            #p{pid = Pid, user = User, comm = Comm, ctx = Ctx};
                        _ ->
                            not_parsed
                    end;
                _ ->
                    not_parsed
            end;
        _ ->
            not_parsed
    end.

%% Extract SELinux type/domain (3rd field) from context
domain_from_ctx(CtxStr) ->
    Parts = string:split(CtxStr, ":", all),
    case Parts of
        [_U, _R, T | _] -> T;
        _ -> CtxStr
    end.

%% Tokenizers
take_token(Str0) ->
    Str = string:trim(Str0),
    case string:split(Str, " ", leading) of
        [Tok, Rest] -> {Tok, Rest};
        _ -> error
    end.

scan_int(Str0) ->
    Str = string:trim(Str0),
    Dig = take_while(fun is_digit/1, Str),
    case Dig of
        "" -> error;
        _ -> {list_to_integer(Dig), lists:nthtail(length(Dig), Str)}
    end.

scan_word(Str0) ->
    Str = string:trim(Str0),
    Word = take_while(fun is_word/1, Str),
    case Word of
        "" -> error;
        _ -> {Word, lists:nthtail(length(Word), Str)}
    end.

take_while(Pred, [H | T]) ->
    case Pred(H) of
        true -> [H | take_while(Pred, T)];
        false -> []
    end;
take_while(_Pred, []) ->
    [].

is_digit($0) -> true;
is_digit($1) -> true;
is_digit($2) -> true;
is_digit($3) -> true;
is_digit($4) -> true;
is_digit($5) -> true;
is_digit($6) -> true;
is_digit($7) -> true;
is_digit($8) -> true;
is_digit($9) -> true;
is_digit(_) -> false.

is_word($_) -> true;
is_word($-) -> true;
is_word($.) -> true;
is_word(C) when C >= $A, C =< $Z -> true;
is_word(C) when C >= $a, C =< $z -> true;
is_word(C) when C >= $0, C =< $9 -> true;
is_word(_) -> false.

to_list(B) when is_binary(B) -> binary_to_list(B);
to_list(L) when is_list(L) -> L;
to_list(A) when is_atom(A) -> atom_to_list(A);
to_list(I) when is_integer(I) -> integer_to_list(I).

%% ===== Name sanitization & TE builder ==============================

-spec sanitize_name(term()) -> string().
sanitize_name(N) ->
    %% lower-case and replace non [A-Za-z0-9_.-] with underscore
    L = string:to_lower(to_list(N)),
    Safe = [
        case is_word(C) of
            true -> C;
            false -> $_
        end
     || C <- L
    ],
    lists:concat(Safe).

-spec build_te(string()) -> iolist().
build_te(Name) ->
    %% minimal template; tighten in staging using audit logs
    io_lib:format(
        "module(~s, 1.0)\n"
        "\n"
        "require {\n"
        "  type unconfined_t;\n"
        "  class process transition;\n"
        "}\n"
        "\n"
        "type ~s_t;\n"
        "domain_type(~s_t)\n"
        "\n"
        "allow unconfined_t ~s_t:process transition;\n"
        "\n"
        "/* TODO:\n"
        "   - declare file types (e.g., ~s_var_run_t) and fcontexts\n"
        "   - restrict caps/sockets/files to the minimum needed\n"
        "   - iterate with ausearch/audit2allow in staging\n"
        "*/\n",
        [Name, Name, Name, Name, Name]
    ).
