%%%-------------------------------------------------------------------
%%% @doc OTP Logger integration for erm.
%%%
%%% Modules should set process metadata to one of the erm domains and can also
%%% pass #{domain => Domain} explicitly to logger macros. ensure_handler/0 adds
%%% a file handler that accepts the [erm | _] domain subtree only.
%%% @end
%%%-------------------------------------------------------------------
-module(erm_log).

-include("erm_log.hrl").
-include_lib("kernel/include/logger.hrl").

-export([
    ensure_handler/0,
    ensure_handler/1,
    log_file/0,
    set_process_domain/1,
    domain_meta/1
]).

-define(DEFAULT_HANDLER_ID, erm_file).
-define(DEFAULT_MAX_BYTES, 10485760).
-define(DEFAULT_MAX_FILES, 5).
-define(DEFAULT_FILESYNC_MS, 5000).

-spec ensure_handler() -> ok | {error, term()}.
ensure_handler() ->
    case application:get_env(erm, log_to_file, true) of
        false -> ok;
        _ -> ensure_handler(log_file())
    end.

-spec ensure_handler(file:filename_all()) -> ok | {error, term()}.
ensure_handler(Path0) ->
    Path = filename:absname(to_text(Path0)),
    case filelib:ensure_dir(Path) of
        ok -> ensure_handler_ready(Path);
        {error, Reason} -> {error, {log_dir_unavailable, Path, Reason}}
    end.

-spec log_file() -> file:filename_all().
log_file() ->
    case application:get_env(erm, log_file) of
        {ok, Path} -> Path;
        undefined -> filename:join([state_root(), "erm", "erm.log"])
    end.

-spec set_process_domain([atom()]) -> ok.
set_process_domain(Domain) when is_list(Domain) ->
    logger:update_process_metadata(domain_meta(Domain)),
    ok.

-spec domain_meta([atom()]) -> map().
domain_meta(Domain) when is_list(Domain) ->
    #{domain => Domain}.

ensure_handler_ready(Path) ->
    HandlerId = handler_id(),
    Config = handler_config(Path),
    case logger:get_handler_config(HandlerId) of
        {ok, _Existing} ->
            ok;
        {error, {not_found, HandlerId}} ->
            add_handler(HandlerId, Config);
        {error, not_found} ->
            add_handler(HandlerId, Config);
        {error, Reason} ->
            {error, {log_handler_lookup_failed, HandlerId, Reason}}
    end.

add_handler(HandlerId, Config) ->
    case logger:add_handler(HandlerId, logger_std_h, Config) of
        ok -> ok;
        {error, {already_exists, HandlerId}} -> ok;
        {error, already_exists} -> ok;
        {error, Reason} -> {error, {log_handler_add_failed, HandlerId, Reason}}
    end.

handler_id() ->
    case application:get_env(erm, log_handler, ?DEFAULT_HANDLER_ID) of
        Id when is_atom(Id) -> Id;
        Other ->
            ?LOG_WARNING(
                "Ignoring invalid erm.log_handler value ~p; using ~p",
                [Other, ?DEFAULT_HANDLER_ID],
                ?ERM_LOG_META(?ERM_LOG_DOMAIN)
            ),
            ?DEFAULT_HANDLER_ID
    end.

handler_config(Path) ->
    Level = application:get_env(erm, log_level, debug),
    #{
        level => Level,
        filter_default => stop,
        filters => #{
            erm_domain => {fun logger_filters:domain/2, {log, sub, ?ERM_LOG_DOMAIN}}
        },
        formatter => {logger_formatter, #{single_line => false}},
        config => #{
            type => file,
            file => Path,
            modes => [raw, append, delayed_write],
            filesync_repeat_interval => application:get_env(
                erm,
                log_filesync_repeat_interval,
                ?DEFAULT_FILESYNC_MS
            ),
            max_no_bytes => application:get_env(erm, log_max_no_bytes, ?DEFAULT_MAX_BYTES),
            max_no_files => application:get_env(erm, log_max_no_files, ?DEFAULT_MAX_FILES)
        }
    }.

state_root() ->
    case os:getenv("XDG_STATE_HOME") of
        false -> fallback_state_root();
        "" -> fallback_state_root();
        Root -> Root
    end.

fallback_state_root() ->
    case os:getenv("HOME") of
        false -> "/tmp";
        Home -> filename:join([Home, ".local", "state"])
    end.

to_text(Value) when is_binary(Value) -> unicode:characters_to_list(Value);
to_text(Value) when is_atom(Value) -> atom_to_list(Value);
to_text(Value) when is_list(Value) -> filename:flatten(Value);
to_text(Value) -> lists:flatten(io_lib:format("~p", [Value])).
