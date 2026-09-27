-module(ecai_code_repair).

-export([
    scan_now/0,
    propose/3,
    propose/4,
    repairs/0,
    repairs/1
]).

scan_now() ->
    ecai_patch_manager:scan_now().

propose(App, Module, Fingerprint) ->
    propose(App, Module, Fingerprint, #{}).

propose(App, Module, Fingerprint0, Opts) when is_atom(App), is_atom(Module), is_map(Opts) ->
    Fingerprint = to_binary(Fingerprint0),
    case ecai_vuln_monitor:findings(App, Module) of
        Report when is_map(Report) ->
            Findings = mget(<<"findings">>, Report, []),
            case find_finding(Fingerprint, Findings) of
                {ok, Finding} -> ecai_patch_sup:propose(App, Module, Finding, Opts);
                not_found -> {error, {finding_not_found, Fingerprint}}
            end;
        Other -> {error, {cannot_load_findings, Other}}
    end.

repairs() -> ecai_learning_store:repairs().
repairs(Fingerprint) -> ecai_learning_store:repairs(Fingerprint).

find_finding(_Fingerprint, []) -> not_found;
find_finding(Fingerprint, [Finding | Rest]) when is_map(Finding) ->
    case mget(<<"fingerprint">>, Finding, <<>>) of
        Fingerprint -> {ok, Finding};
        _ -> find_finding(Fingerprint, Rest)
    end;
find_finding(Fingerprint, [_ | Rest]) -> find_finding(Fingerprint, Rest).

mget(Key, Map, Default) when is_map(Map), is_binary(Key) ->
    case maps:find(Key, Map) of
        {ok, V} -> V;
        error ->
            try binary_to_existing_atom(Key, utf8) of
                A -> maps:get(A, Map, Default)
            catch error:badarg -> Default end
    end;
mget(_Key, _Map, Default) -> Default.

to_binary(B) when is_binary(B) -> B;
to_binary(L) when is_list(L) -> unicode:characters_to_binary(L);
to_binary(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_binary(V) -> iolist_to_binary(io_lib:format("~p", [V])).
