-module(damage_logger_filters).

-export([module_only/2, add_domain_by_module_prefix/2]).

%% Legacy exact-module selector. Prefer logger_filters:domain/2 for project code
%% that can attach a domain at the log call site.
module_only(#{meta := #{mfa := {Module, _, _}}} = LogEvent, Module) ->
    LogEvent;
module_only(_, _) ->
    stop.

%% Migration bridge for ERM Lens modules not yet converted to explicit Logger
%% domains (for example erm_lens_sync). It enriches metadata only; the actual
%% routing decision is still made by OTP's logger_filters:domain/2.
%%
%% Return ignore for unrelated/already-tagged events so subsequent filters see
%% the original event and can make the normal decision.
add_domain_by_module_prefix(
    #{meta := Meta} = LogEvent,
    {Prefix0, Domain}
) when is_list(Domain) ->
    case maps:is_key(domain, Meta) of
        true ->
            ignore;
        false ->
            case maps:get(mfa, Meta, undefined) of
                {Module, _, _} when is_atom(Module) ->
                    Prefix = normalize_prefix(Prefix0),
                    case lists:prefix(Prefix, atom_to_list(Module)) of
                        true -> LogEvent#{meta => Meta#{domain => Domain}};
                        false -> ignore
                    end;
                _ ->
                    ignore
            end
    end;
add_domain_by_module_prefix(_LogEvent, _Args) ->
    ignore.

normalize_prefix(Prefix) when is_binary(Prefix) -> binary_to_list(Prefix);
normalize_prefix(Prefix) when is_atom(Prefix) -> atom_to_list(Prefix);
normalize_prefix(Prefix) when is_list(Prefix) -> Prefix.
