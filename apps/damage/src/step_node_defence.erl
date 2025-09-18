%%%-------------------------------------------------------------------
%%% DamageBDD - Node Defence Steps
%%% Firewall (iptables/nft), sysctl, sshd, ports, fail2ban — assert + [MUTATE]
%%%-------------------------------------------------------------------
-module(step_node_defence).
-author("Steven Joseph <steven@stevenjoseph.in>").
-copyright("Steven Joseph <steven@stevenjoseph.in>").
-license("Apache-2.0").

-export([step/6]).

-include_lib("kernel/include/logger.hrl").
-include_lib("damage.hrl").

%% ---------- Helpers ----------
sudo_prefix(#{sudo := true}) -> "sudo ";
sudo_prefix(_) -> "".

run(Ctx, CmdStr) ->
    exec:run(
        CmdStr,
        [sync, stderr, stdout, {cd, filename:absname(maps:get(cmd_cwd, Ctx, "/tmp"))}]
    ).

ensure_admin(#{public_key := AeAccount}) ->
    case steps_utils:is_admin(AeAccount) of
        true -> ok;
        false -> {error, not_admin}
    end;
ensure_admin(_) ->
    {error, not_admin}.

set_fail(Ctx, Fmt, Args) ->
    maps:put(fail, damage_utils:strf(Fmt, Args), Ctx).

trim(S) when is_binary(S) -> string:trim(S);
trim(S) when is_list(S) -> string:trim(S);
trim(S) -> S.

re_ok(Text, Rx) ->
    case re:run(Text, Rx) of
        {match, _} -> true;
        _ -> false
    end.

%% ---------- Context / sudo ----------
step(_Cfg, Ctx, <<"Given">>, _N, ["I use sudo is", "true"], _) ->
    maps:put(sudo, true, Ctx);
step(_Cfg, Ctx, <<"Given">>, _N, ["I use sudo is", "false"], _) ->
    maps:put(sudo, false, Ctx);
%% ---------- Tool presence ----------
step(_Cfg, Ctx, <<"Then">>, _N, [Tool, "is available"], _) ->
    case run(Ctx, "command -v " ++ Tool) of
        {ok, _} -> Ctx;
        {error, E} -> set_fail(Ctx, "Tool ~p not found (~p)", [Tool, E])
    end;
%% ---------- iptables (assert) ----------
step(_Cfg, Ctx, <<"Then">>, _N, ["iptables chain", Chain, "must exist"], _) ->
    case run(Ctx, "iptables -S " ++ Chain) of
        {ok, _} -> Ctx;
        {error, E} -> set_fail(Ctx, "iptables chain ~p missing (~p)", [Chain, E])
    end;
step(
    _Cfg,
    Ctx,
    <<"Then">>,
    _N,
    ["iptables must have a rule matching", Regex, "in chain", Chain],
    _
) ->
    case run(Ctx, "iptables -S " ++ Chain) of
        {ok, #{stdout := Out}} ->
            case re_ok(Out, Regex) of
                true -> Ctx;
                false -> set_fail(Ctx, "No iptables rule matching ~p in ~p", [Regex, Chain])
            end;
        {error, E} ->
            set_fail(Ctx, "iptables -S failed (~p)", [E])
    end;
%% ---------- iptables (mutate) ----------
step(_Cfg, Ctx0, <<"When">>, _N, ["I append iptables rule", Rule, "to chain", Chain], _) ->
    case ensure_admin(Ctx0) of
        ok ->
            Cmd = sudo_prefix(Ctx0) ++ "iptables -A " ++ Chain ++ " " ++ Rule,
            case run(Ctx0, Cmd) of
                {ok, _} -> Ctx0;
                {error, E} -> set_fail(Ctx0, "Failed to append rule to ~p: ~p", [Chain, E])
            end;
        {error, _} ->
            set_fail(Ctx0, "Admin privileges required", [])
    end;
step(_Cfg, Ctx0, <<"When">>, _N, ["I delete iptables rule", Rule, "from chain", Chain], _) ->
    case ensure_admin(Ctx0) of
        ok ->
            Cmd = sudo_prefix(Ctx0) ++ "iptables -D " ++ Chain ++ " " ++ Rule,
            case run(Ctx0, Cmd) of
                {ok, _} -> Ctx0;
                {error, E} -> set_fail(Ctx0, "Failed to delete rule from ~p: ~p", [Chain, E])
            end;
        {error, _} ->
            set_fail(Ctx0, "Admin privileges required", [])
    end;
%% ---------- nftables ----------
step(_Cfg, Ctx, <<"Then">>, _N, ["nftables list must contain", Regex], _) ->
    case run(Ctx, "nft list ruleset") of
        {ok, #{stdout := Out}} ->
            case re_ok(Out, Regex) of
                true -> Ctx;
                false -> set_fail(Ctx, "nft ruleset does not match ~p", [Regex])
            end;
        {error, E} ->
            set_fail(Ctx, "nft list ruleset failed (~p)", [E])
    end;
step(_Cfg, Ctx0, <<"When">>, _N, ["I add nft rule", Rule, "to table", Table, "chain", Chain], _) ->
    case ensure_admin(Ctx0) of
        ok ->
            Cmd = sudo_prefix(Ctx0) ++ "nft add rule " ++ Table ++ " " ++ Chain ++ " " ++ Rule,
            case run(Ctx0, Cmd) of
                {ok, _} ->
                    Ctx0;
                {error, E} ->
                    set_fail(Ctx0, "Failed to add nft rule to ~p/~p: ~p", [Table, Chain, E])
            end;
        {error, _} ->
            set_fail(Ctx0, "Admin privileges required", [])
    end;
step(
    _Cfg,
    Ctx0,
    <<"When">>,
    _N,
    ["I delete nft rule handle", Handle, "from table", Table, "chain", Chain],
    _
) ->
    case ensure_admin(Ctx0) of
        ok ->
            Cmd =
                sudo_prefix(Ctx0) ++ "nft delete rule " ++ Table ++ " " ++ Chain ++ " handle " ++
                    Handle,
            case run(Ctx0, Cmd) of
                {ok, _} -> Ctx0;
                {error, E} -> set_fail(Ctx0, "Failed to delete nft rule handle ~p: ~p", [Handle, E])
            end;
        {error, _} ->
            set_fail(Ctx0, "Admin privileges required", [])
    end;
%% ---------- sysctl ----------
step(_Cfg, Ctx, <<"Then">>, _N, ["sysctl key", Key, "must be", Val], _) ->
    case run(Ctx, "sysctl -n " ++ Key) of
        {ok, #{stdout := Out}} ->
            case trim(Out) =:= Val of
                true -> Ctx;
                false -> set_fail(Ctx, "sysctl ~p expected ~p got ~p", [Key, Val, trim(Out)])
            end;
        {error, E} ->
            set_fail(Ctx, "sysctl -n ~p failed (~p)", [Key, E])
    end;
step(_Cfg, Ctx0, <<"When">>, _N, ["I set sysctl key", Key, "to", Val], _) ->
    case ensure_admin(Ctx0) of
        ok ->
            Cmd = sudo_prefix(Ctx0) ++ "sysctl -w " ++ Key ++ "=" ++ Val,
            case run(Ctx0, Cmd) of
                {ok, _} -> Ctx0;
                {error, E} -> set_fail(Ctx0, "Failed to set sysctl ~p: ~p", [Key, E])
            end;
        {error, _} ->
            set_fail(Ctx0, "Admin privileges required", [])
    end;
%% ---------- SSHD ----------
step(_Cfg, Ctx, <<"Then">>, _N, ["SSH must disallow password auth"], _) ->
    case run(Ctx, "sshd -T") of
        {ok, #{stdout := Out}} ->
            case re_ok(Out, "passwordauthentication\\s+no") of
                true -> Ctx;
                false -> set_fail(Ctx, "SSH allows password authentication", [])
            end;
        {error, E} ->
            set_fail(Ctx, "sshd -T failed (~p)", [E])
    end;
step(_Cfg, Ctx0, <<"When">>, _N, ["I set sshd_config", Key, "to", Val, "and reload"], _) ->
    case ensure_admin(Ctx0) of
        ok ->
            Sudo = sudo_prefix(Ctx0),
            Cmd = io_lib:format(
                "~sbash -lc 'set -e; sed -i -r \"s|^#?~s\\s+.*|~s ~s|\" /etc/ssh/sshd_config && ~ssystemctl reload sshd'",
                [Sudo, Key, Key, Val, Sudo]
            ),
            case run(Ctx0, lists:flatten(Cmd)) of
                {ok, _} -> Ctx0;
                {error, E} -> set_fail(Ctx0, "Failed to set sshd_config ~p: ~p", [Key, E])
            end;
        {error, _} ->
            set_fail(Ctx0, "Admin privileges required", [])
    end;
%% ---------- Ports ----------
step(_Cfg, Ctx, <<"Then">>, _N, ["port", Port, "must be", "open", "tcp"], _) ->
    case run(Ctx, "ss -lnt") of
        {ok, #{stdout := Out}} ->
            %% Look for ":<Port>" token
            Pattern = ":" ++ Port ++ "(\\s|$)",
            case re_ok(Out, Pattern) of
                true -> Ctx;
                false -> set_fail(Ctx, "TCP port ~p is not open", [Port])
            end;
        {error, E} ->
            set_fail(Ctx, "ss -lnt failed (~p)", [E])
    end;
step(_Cfg, Ctx, <<"Then">>, _N, ["port", Port, "must be", "closed", "tcp"], _) ->
    case run(Ctx, "ss -lnt") of
        {ok, #{stdout := Out}} ->
            Pattern = ":" ++ Port ++ "(\\s|$)",
            case re_ok(Out, Pattern) of
                true -> set_fail(Ctx, "TCP port ~p is open", [Port]);
                false -> Ctx
            end;
        {error, E} ->
            set_fail(Ctx, "ss -lnt failed (~p)", [E])
    end.
