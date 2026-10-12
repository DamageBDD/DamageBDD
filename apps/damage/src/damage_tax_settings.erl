%%%-------------------------------------------------------------------
%%% Tax-only projection/allowlist for the versioned node settings service.
%%% A tax_admin must not read or mutate any unrelated DamageBDD configuration.
%%% The operator-administered tax_admins allowlist is NEVER an editable field.
%%%-------------------------------------------------------------------
-module(damage_tax_settings).
-export([keys/0, authorized_changes/1, authorized_resets/1, project/1, read_view/0]).

-define(TAX_KEYS, [
    <<"tax_enabled">>,
    <<"tax_cln_owner">>,
    <<"tax_data_dir">>,
    <<"tax_backfill_on_start">>,
    <<"tax_jurisdiction">>,
    <<"tax_standard_utc_offset_minutes">>,
    <<"tax_max_prices_per_backfill">>,
    <<"tax_price_pause_ms">>
]).

keys() -> ?TAX_KEYS.

-spec authorized_changes(term()) -> boolean().
authorized_changes(Changes) when is_map(Changes), map_size(Changes) =< length(?TAX_KEYS) ->
    lists:all(fun(Key) -> allowed_key(Key) end, maps:keys(Changes));
authorized_changes(_) ->
    false.

-spec authorized_resets(term()) -> boolean().
authorized_resets(Names) when is_list(Names), length(Names) =< length(?TAX_KEYS) ->
    lists:all(fun(Key) -> allowed_key(Key) end, Names) andalso
        length(lists:usort(Names)) =:= length(Names);
authorized_resets(_) ->
    false.

allowed_key(Name) when is_binary(Name) -> lists:member(Name, ?TAX_KEYS);
allowed_key(_) -> false.

read_view() ->
    case damage_settings:get(damage) of
        {ok, Settings} -> {ok, project(Settings)};
        {error, _} = Error -> Error
    end.

%% Keep the optimistic-concurrency version but strip unrelated fields,
%% discovered protected keys, operator filesystem config paths and errors.
project(#{fields := Fields, version := Version} = Settings) ->
    TaxFields = [tax_field(F) || #{name := Name} = F <- Fields, allowed_key(Name)],
    Pending = [
        P
     || P <- maps:get(pending_restart, Settings, []),
        is_binary(P),
        lists:member(P, [<<"damage.", K/binary>> || K <- ?TAX_KEYS])
    ],
    #{
        version => Version,
        fields => TaxFields,
        pending_restart => Pending,
        restart_required => Pending =/= [],
        running => application:get_env(damage, tax_enabled, false) =:= true
    }.

%% Country names come from the backend registry; the browser cannot grant
%% itself additional editable keys or invent jurisdiction identifiers.
tax_field(#{name := <<"tax_jurisdiction">>} = F) ->
    Options = [
        #{
            value => maps:get(<<"code">>, Profile),
            label => maps:get(<<"name">>, Profile)
        }
     || Profile <- damage_tax_regions:all()
    ],
    F#{options => Options};
tax_field(F) ->
    F.
