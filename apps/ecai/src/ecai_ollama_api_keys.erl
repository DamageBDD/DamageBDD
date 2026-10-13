%% Account-scoped bearer keys for the Ollama-compatible ECAI gateway.
%% Plaintext secrets are returned once and never persisted.
-module(ecai_ollama_api_keys).
-behaviour(gen_server).

-export([
    start_link/0,
    start_link/1,
    list/1,
    create/2,
    rotate/2,
    revoke/2,
    authenticate/1,
    has_scope/2
]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(st, {table}).

-define(TOKEN_PREFIX, <<"ecai_ollama_">>).
-define(DEFAULT_LIMIT, 20).
-define(TOUCH_INTERVAL_MS, 60000).
-define(MAX_LABEL_BYTES, 80).
-define(MAX_EXPIRY_DAYS, 3650).
-define(ALLOWED_SCOPES, [<<"models">>, <<"chat">>, <<"generate">>]).

start_link() -> start_link(#{}).
start_link(Opts) -> gen_server:start_link({local, ?MODULE}, ?MODULE, Opts, []).

list(Owner) -> gen_server:call(?MODULE, {list, Owner}, 30000).
create(Owner, Params) -> gen_server:call(?MODULE, {create, Owner, Params}, 30000).
rotate(Owner, Id) -> gen_server:call(?MODULE, {rotate, Owner, Id}, 30000).
revoke(Owner, Id) -> gen_server:call(?MODULE, {revoke, Owner, Id}, 30000).
authenticate(Token) -> gen_server:call(?MODULE, {authenticate, Token}, 5000).

has_scope(#{scopes := Scopes}, Scope) when is_list(Scopes) -> lists:member(Scope, Scopes);
has_scope(_, _) -> false.

init(Opts) ->
    DefaultPath = filename:join(ecai_paths:index_state_dir(), "ollama_api_keys.dets"),
    Path = ecai_paths:normalize(
        maps:get(
            path,
            Opts,
            application:get_env(ecai, ollama_api_keys_path, DefaultPath)
        )
    ),
    ok = ecai_paths:ensure_parent(Path),
    case
        dets:open_file(
            ecai_ollama_api_keys_dets,
            [{file, Path}, {type, set}, {auto_save, 1000}]
        )
    of
        {ok, Table} -> {ok, #st{table = Table}};
        {error, Reason} -> {stop, {ollama_api_key_store_failed, Reason}}
    end.

handle_call({list, Owner}, _From, State = #st{table = T}) ->
    Entries = dets:foldl(
        fun
            ({{key, _Id}, Entry}, Acc) ->
                case maps:get(owner, Entry, undefined) =:= Owner of
                    true -> [public_entry(Entry) | Acc];
                    false -> Acc
                end;
            (_, Acc) ->
                Acc
        end,
        [],
        T
    ),
    Sorted = lists:sort(
        fun(A, B) ->
            maps:get(<<"created_at_ms">>, A, 0) > maps:get(<<"created_at_ms">>, B, 0)
        end,
        Entries
    ),
    {reply, {ok, Sorted}, State};
handle_call({create, Owner, Params}, _From, State = #st{table = T}) ->
    Reply =
        case validate_owner(Owner) of
            ok -> create_key(T, Owner, Params, true);
            Error -> {error, Error}
        end,
    {reply, Reply, State};
handle_call({rotate, Owner, Id}, _From, State = #st{table = T}) ->
    Reply =
        case owned_entry(T, Owner, Id) of
            {ok, Entry} ->
                case entry_status(Entry, now_ms()) of
                    revoked -> {error, key_revoked};
                    _ -> rotate_key(T, Entry)
                end;
            Error ->
                Error
        end,
    {reply, Reply, State};
handle_call({revoke, Owner, Id}, _From, State = #st{table = T}) ->
    Reply =
        case owned_entry(T, Owner, Id) of
            {ok, Entry} ->
                case maps:get(revoked_at_ms, Entry, null) of
                    Revoked when is_integer(Revoked) -> {ok, public_entry(Entry)};
                    _ ->
                        New = Entry#{revoked_at_ms => now_ms()},
                        save_entry(T, New, {ok, public_entry(New)})
                end;
            Error ->
                Error
        end,
    {reply, Reply, State};
handle_call({authenticate, Token}, _From, State = #st{table = T}) ->
    Reply = authenticate_token(T, Token),
    {reply, Reply, State};
handle_call(_, _From, State) ->
    {reply, {error, unsupported_operation}, State}.
handle_cast(_, State) -> {noreply, State}.
handle_info(_, State) -> {noreply, State}.
terminate(_, #st{table = T}) -> dets:close(T).
code_change(_, State, _) -> {ok, State}.

create_key(T, Owner, Params, EnforceLimit) when is_map(Params) ->
    case validate_create_params(Params) of
        {ok, Label, Scopes, ExpiresAt} ->
            case EnforceLimit andalso active_count(T, Owner) >= key_limit() of
                true -> {error, active_key_limit_reached};
                false -> issue_key(T, Owner, Label, Scopes, ExpiresAt)
            end;
        Error ->
            Error
    end;
create_key(_, _, _, _) ->
    {error, invalid_key_request}.

issue_key(T, Owner, Label, Scopes, ExpiresAt) ->
    Id = binary:encode_hex(crypto:strong_rand_bytes(10)),
    Secret = base64url(crypto:strong_rand_bytes(32)),
    Token = <<?TOKEN_PREFIX/binary, Id/binary, ".", Secret/binary>>,
    Now = now_ms(),
    Entry = #{
        id => Id,
        owner => Owner,
        label => Label,
        scopes => Scopes,
        secret_hash => crypto:hash(sha256, Secret),
        created_at_ms => Now,
        last_used_at_ms => null,
        expires_at_ms => ExpiresAt,
        revoked_at_ms => null
    },
    case save_entry(T, Entry, ok) of
        ok -> {ok, #{key => public_entry(Entry), secret => Token}};
        {error, _} = Error -> Error
    end.

rotate_key(T, Old) ->
    Owner = maps:get(owner, Old),
    Label = maps:get(label, Old),
    Scopes = maps:get(scopes, Old, ?ALLOWED_SCOPES),
    ExpiresAt = maps:get(expires_at_ms, Old, null),
    RevokedOld = Old#{revoked_at_ms => now_ms()},
    case save_entry(T, RevokedOld, ok) of
        ok ->
            case issue_key(T, Owner, Label, Scopes, ExpiresAt) of
                {ok, Result} ->
                    {ok, Result#{replaced_key_id => maps:get(id, Old)}};
                {error, Reason} ->
                    %% Keep the old key usable if the replacement could not be persisted.
                    _ = save_entry(T, Old, ok),
                    {error, Reason}
            end;
        {error, _} = Error ->
            Error
    end.

authenticate_token(T, Token) when is_binary(Token) ->
    case parse_token(Token) of
        {ok, Id, Secret} ->
            Key = {key, Id},
            case dets:lookup(T, Key) of
                [{Key, Entry}] -> authenticate_entry(T, Entry, Secret);
                _ -> {error, invalid_key}
            end;
        error ->
            {error, invalid_key}
    end;
authenticate_token(_, _) ->
    {error, invalid_key}.

authenticate_entry(T, Entry, Secret) ->
    Expected = maps:get(secret_hash, Entry, <<>>),
    Actual = crypto:hash(sha256, Secret),
    case secure_equal(Expected, Actual) of
        false ->
            {error, invalid_key};
        true ->
            Now = now_ms(),
            case entry_status(Entry, Now) of
                revoked ->
                    {error, key_revoked};
                expired ->
                    {error, key_expired};
                active ->
                    Updated = maybe_touch(T, Entry, Now),
                    {ok, #{
                        owner => maps:get(owner, Updated),
                        id => maps:get(id, Updated),
                        label => maps:get(label, Updated),
                        scopes => maps:get(scopes, Updated, ?ALLOWED_SCOPES)
                    }}
            end
    end.

maybe_touch(T, Entry, Now) ->
    Last = maps:get(last_used_at_ms, Entry, null),
    case Last =:= null orelse (is_integer(Last) andalso Now - Last >= ?TOUCH_INTERVAL_MS) of
        true ->
            New = Entry#{last_used_at_ms => Now},
            case save_entry(T, New, ok) of
                ok -> New;
                _ -> Entry
            end;
        false ->
            Entry
    end.

owned_entry(T, Owner, Id) when is_binary(Id), byte_size(Id) =:= 20 ->
    Key = {key, Id},
    case dets:lookup(T, Key) of
        [{Key, Entry}] ->
            case maps:get(owner, Entry, undefined) =:= Owner of
                true -> {ok, Entry};
                false -> {error, key_not_found}
            end;
        _ ->
            {error, key_not_found}
    end;
owned_entry(_, _, _) ->
    {error, key_not_found}.

active_count(T, Owner) ->
    Now = now_ms(),
    dets:foldl(
        fun
            ({{key, _}, Entry}, Acc) ->
                case
                    maps:get(owner, Entry, undefined) =:= Owner andalso
                        entry_status(Entry, Now) =:= active
                of
                    true -> Acc + 1;
                    false -> Acc
                end;
            (_, Acc) ->
                Acc
        end,
        0,
        T
    ).

validate_create_params(Params) ->
    Allowed = [<<"label">>, <<"scopes">>, <<"expires_in_days">>],
    case lists:all(fun(K) -> lists:member(K, Allowed) end, maps:keys(Params)) of
        false ->
            {error, unexpected_fields};
        true ->
            Label0 = maps:get(<<"label">>, Params, <<"Ollama client">>),
            Scopes0 = maps:get(<<"scopes">>, Params, ?ALLOWED_SCOPES),
            Expiry0 = maps:get(<<"expires_in_days">>, Params, null),
            case {validate_label(Label0), validate_scopes(Scopes0), expiry(Expiry0)} of
                {{ok, Label}, {ok, Scopes}, {ok, ExpiresAt}} ->
                    {ok, Label, Scopes, ExpiresAt};
                {{error, Reason}, _, _} ->
                    {error, Reason};
                {_, {error, Reason}, _} ->
                    {error, Reason};
                {_, _, {error, Reason}} ->
                    {error, Reason}
            end
    end.

validate_label(Label0) when is_binary(Label0) ->
    Label = string:trim(Label0),
    case byte_size(Label) >= 1 andalso byte_size(Label) =< ?MAX_LABEL_BYTES of
        true -> {ok, Label};
        false -> {error, invalid_label}
    end;
validate_label(_) ->
    {error, invalid_label}.

validate_scopes(Scopes) when is_list(Scopes), Scopes =/= [] ->
    Unique = lists:usort(Scopes),
    case lists:all(fun(S) -> is_binary(S) andalso lists:member(S, ?ALLOWED_SCOPES) end, Unique) of
        true -> {ok, Unique};
        false -> {error, invalid_scopes}
    end;
validate_scopes(_) ->
    {error, invalid_scopes}.

expiry(null) ->
    {ok, null};
expiry(undefined) ->
    {ok, null};
expiry(0) ->
    {ok, null};
expiry(Days) when is_integer(Days), Days >= 1, Days =< ?MAX_EXPIRY_DAYS ->
    {ok, now_ms() + Days * 86400000};
expiry(_) ->
    {error, invalid_expiry}.

validate_owner(Owner) when is_binary(Owner), byte_size(Owner) > 0, byte_size(Owner) =< 512 -> ok;
validate_owner(_) -> invalid_owner.

entry_status(Entry, Now) ->
    case maps:get(revoked_at_ms, Entry, null) of
        Revoked when is_integer(Revoked) -> revoked;
        _ ->
            case maps:get(expires_at_ms, Entry, null) of
                Expires when is_integer(Expires), Expires =< Now -> expired;
                _ -> active
            end
    end.

public_entry(Entry) ->
    Status = entry_status(Entry, now_ms()),
    Id = maps:get(id, Entry),
    #{
        <<"id">> => Id,
        <<"label">> => maps:get(label, Entry),
        <<"hint">> => <<?TOKEN_PREFIX/binary, Id/binary, ".****">>,
        <<"scopes">> => maps:get(scopes, Entry, ?ALLOWED_SCOPES),
        <<"status">> => atom_to_binary(Status, utf8),
        <<"created_at_ms">> => maps:get(created_at_ms, Entry),
        <<"last_used_at_ms">> => maps:get(last_used_at_ms, Entry, null),
        <<"expires_at_ms">> => maps:get(expires_at_ms, Entry, null),
        <<"revoked_at_ms">> => maps:get(revoked_at_ms, Entry, null)
    }.

save_entry(T, Entry, Response) ->
    Key = {key, maps:get(id, Entry)},
    case dets:insert(T, {Key, Entry}) of
        ok ->
            case dets:sync(T) of
                ok -> Response;
                Error -> {error, {sync_failed, Error}}
            end;
        Error ->
            {error, {write_failed, Error}}
    end.

parse_token(Token) when is_binary(Token) ->
    Prefix = ?TOKEN_PREFIX,
    PrefixSize = byte_size(Prefix),
    case Token of
        <<Prefix:PrefixSize/binary, Rest/binary>> ->
            case binary:split(Rest, <<".">>, [global]) of
                [Id, Secret] when
                    byte_size(Id) =:= 20,
                    byte_size(Secret) >= 40,
                    byte_size(Secret) =< 64
                ->
                    {ok, Id, Secret};
                _ ->
                    error
            end;
        _ ->
            error
    end;
parse_token(_) ->
    error.

secure_equal(A, B) when is_binary(A), is_binary(B), byte_size(A) =:= byte_size(B) ->
    0 =:=
        lists:foldl(
            fun({X, Y}, Acc) -> Acc bor (X bxor Y) end,
            0,
            lists:zip(binary_to_list(A), binary_to_list(B))
        );
secure_equal(_, _) ->
    false.

base64url(Bytes) ->
    Enc0 = base64:encode(Bytes),
    Enc1 = binary:replace(Enc0, <<"+">>, <<"-">>, [global]),
    Enc2 = binary:replace(Enc1, <<"/">>, <<"_">>, [global]),
    binary:replace(Enc2, <<"=">>, <<>>, [global]).

key_limit() ->
    case application:get_env(ecai, ollama_api_key_limit_per_account, ?DEFAULT_LIMIT) of
        I when is_integer(I), I >= 1, I =< 1000 -> I;
        _ -> ?DEFAULT_LIMIT
    end.

now_ms() -> erlang:system_time(millisecond).
