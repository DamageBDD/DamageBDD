%%--------------------------------------------------------------------
%% Explicit IMDSv2 validation. No tokenless metadata request exists here.
%%--------------------------------------------------------------------
-module(damage_aws_imdsv2).

-export([validate_role/1, validate_role/2]).

-define(IMDS_BASE, "http://169.254.169.254").
-define(HTTP_OPTIONS, [{connect_timeout, 500}, {timeout, 1500}]).
-define(REQUEST_OPTIONS, [{body_format, binary}]).

-spec validate_role(binary() | string()) -> {ok, map()} | {error, term()}.
validate_role(ExpectedRole) ->
    validate_role(ExpectedRole, fun httpc:request/4).

-spec validate_role(binary() | string(), function()) -> {ok, map()} | {error, term()}.
validate_role(ExpectedRole0, RequestFun) when is_function(RequestFun, 4) ->
    ExpectedRole = to_binary(ExpectedRole0),
    case ExpectedRole of
        <<>> ->
            {error, expected_instance_role_required};
        _ ->
            case application:ensure_all_started(inets) of
                {ok, _} -> request_token(ExpectedRole, RequestFun);
                {error, Reason} -> {error, {inets_start_failed, safe_reason(Reason)}}
            end
    end;
validate_role(_, _) ->
    {error, invalid_request_function}.

request_token(ExpectedRole, RequestFun) ->
    Url = ?IMDS_BASE ++ "/latest/api/token",
    Headers = [{"X-aws-ec2-metadata-token-ttl-seconds", "60"}],
    Request = {Url, Headers, "text/plain", <<>>},
    case RequestFun(put, Request, ?HTTP_OPTIONS, ?REQUEST_OPTIONS) of
        {ok, {{_Version, 200, _Phrase}, _ResponseHeaders, Token0}} when
            is_binary(Token0)
        ->
            case trim(Token0) of
                <<>> -> {error, empty_imdsv2_token};
                Token -> request_role(Token, ExpectedRole, RequestFun)
            end;
        {ok, {{_Version, Status, _Phrase}, _Headers, _Body}} ->
            {error, {imdsv2_token_http_status, Status}};
        {error, Reason} ->
            {error, {imdsv2_token_request_failed, safe_reason(Reason)}};
        _ ->
            {error, invalid_imdsv2_token_response}
    end.

request_role(Token, ExpectedRole, RequestFun) ->
    Url = ?IMDS_BASE ++ "/latest/meta-data/iam/security-credentials/",
    Headers = [{"X-aws-ec2-metadata-token", binary_to_list(Token)}],
    case RequestFun(get, {Url, Headers}, ?HTTP_OPTIONS, ?REQUEST_OPTIONS) of
        {ok, {{_Version, 200, _Phrase}, _ResponseHeaders, Body}} when
            is_binary(Body)
        ->
            validate_role_body(Body, ExpectedRole);
        {ok, {{_Version, Status, _Phrase}, _Headers, _Body}} ->
            {error, {imdsv2_role_http_status, Status}};
        {error, Reason} ->
            {error, {imdsv2_role_request_failed, safe_reason(Reason)}};
        _ ->
            {error, invalid_imdsv2_role_response}
    end.

validate_role_body(Body, ExpectedRole) ->
    Roles = [
        Role
     || Line <- binary:split(Body, <<"\n">>, [global]),
        Role <- [trim(Line)],
        Role =/= <<>>
    ],
    case Roles of
        [ExpectedRole] -> {ok, #{protocol => imdsv2, role_name => ExpectedRole}};
        [ActualRole] -> {error, {unexpected_instance_role, ActualRole}};
        [] -> {error, instance_profile_role_missing};
        _ -> {error, unexpected_instance_profile_roles}
    end.

trim(Bin) -> unicode:characters_to_binary(string:trim(binary_to_list(Bin))).

safe_reason(timeout) -> timeout;
safe_reason({failed_connect, _}) -> failed_connect;
safe_reason(Reason) when is_atom(Reason) -> Reason;
safe_reason(_) -> request_failed.

to_binary(Value) when is_binary(Value) -> Value;
to_binary(Value) when is_list(Value) -> unicode:characters_to_binary(Value);
to_binary(Value) when is_atom(Value) -> atom_to_binary(Value, utf8);
to_binary(_) -> <<>>.
