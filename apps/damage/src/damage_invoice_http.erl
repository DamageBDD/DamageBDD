%% Private enterprise billing API. Explicit Bearer credentials only: no query
%% tokens, cookie-only writes, public Lightning payment requests or L402 auth.
-module(damage_invoice_http).
-license("Apache-2.0").
-export([trails/0, init/2]).
-ifdef(TEST).
-export([route/3, bearer/1]).
-endif.
-define(MAX_BODY, 262144).

trails() ->
    [trails:trail("/api/billing/[...]", ?MODULE, #{},
       #{get => #{tags => ["Enterprise Billing"], produces => ["application/json", "application/pdf"]},
         post => #{tags => ["Enterprise Billing"], produces => ["application/json"]},
         put => #{tags => ["Enterprise Billing"], produces => ["application/json"]}})].

init(Req0, _Opts) ->
    Req = try handle(Req0) catch
        throw:{http, Code, Message, R} -> json(Code, #{status => <<"error">>, message => Message}, R);
        _:_ -> json(503, #{status => <<"error">>, message => <<"Billing service unavailable">>}, Req0)
    end,
    {ok, Req, #{}}.

handle(Req0) ->
    case bearer(cowboy_req:header(<<"authorization">>, Req0, <<>>)) of
        {ok, Token} ->
            case damage_access_token:verify_token(Token) of
                {ok, Account, _} when is_binary(Account) -> authenticated(Account, Req0);
                _ -> unauthorized(Req0)
            end;
        error -> unauthorized(Req0)
    end.
bearer(<<"Bearer ", Token/binary>>) when byte_size(Token) > 0, byte_size(Token) =< 8192 ->
    {ok, Token};
bearer(_) -> error.
unauthorized(Req) ->
    json(401, #{status => <<"error">>, message => <<"An authenticated Bearer token is required">>},
         cowboy_req:set_resp_header(<<"www-authenticate">>, <<"Bearer">>, Req)).

authenticated(Account, Req0) ->
    Method = cowboy_req:method(Req0), Path = cowboy_req:path_info(Req0),
    {Body, Req} = case Method of
        <<"GET">> -> {maps:from_list(cowboy_req:parse_qs(Req0)), Req0};
        <<"POST">> -> read_json(Req0);
        <<"PUT">> -> read_json(Req0);
        _ -> throw({http, 405, <<"Method not allowed">>,
                    cowboy_req:set_resp_header(<<"allow">>, <<"GET, POST, PUT">>, Req0)})
    end,
    try route(Method, Path, Body) of
        Command ->
            case damage_enterprise_invoices:request(Account, Command) of
                {ok, Data} -> json(success_code(Command), #{status => <<"ok">>, data => Data}, Req);
                {pdf, Number, PDF} ->
                    Headers = (headers())#{<<"content-type">> => <<"application/pdf">>,
                        <<"content-disposition">> => <<"attachment; filename=\"", Number/binary, ".pdf\"">>},
                    cowboy_req:reply(200, Headers, PDF, Req);
                {error, forbidden} -> json(403, error_body(<<"Invoice administrator permission is required">>), Req);
                {error, not_found} -> json(404, error_body(<<"Billing record not found">>), Req);
                {error, {validation, Msg}} -> json(400, error_body(Msg), Req);
                {error, {conflict, Msg}} -> json(409, error_body(Msg), Req);
                _ -> json(503, error_body(<<"Billing disabled, locked, or storage unavailable">>), Req)
            end
    catch
        throw:not_found -> json(404, error_body(<<"Billing route not found">>), Req);
        throw:{validation, ValidationMessage} -> json(400, error_body(ValidationMessage), Req)
    end.

route(<<"GET">>, [<<"session">>], _) -> session;
route(<<"GET">>, [<<"customers">>], _) -> {list, customers};
route(<<"GET">>, [<<"plans">>], _) -> {list, plans};
route(<<"GET">>, [<<"invoices">>], Q) -> {list_invoices, Q};
route(<<"GET">>, [<<"invoices">>, Id], _) -> {get_invoice, valid_id(Id)};
route(<<"GET">>, [<<"invoices">>, Id, <<"pdf">>], _) -> {get_pdf, valid_id(Id)};
route(<<"POST">>, [<<"customers">>], M) -> {save_customer, body_id(M), M};
route(<<"PUT">>, [<<"customers">>, Id], M) -> {save_customer, matching_id(Id, M), M};
route(<<"POST">>, [<<"plans">>], M) -> {save_plan, body_id(M), M};
route(<<"PUT">>, [<<"plans">>, Id], M) -> {save_plan, matching_id(Id, M), M};
route(<<"POST">>, [<<"plans">>, Id, <<"generate">>], M) -> {generate, valid_id(Id), M};
route(<<"PUT">>, [<<"invoices">>, Id], M) -> {edit_invoice, valid_id(Id), M};
route(<<"POST">>, [<<"invoices">>, Id, Action], M) ->
    case lists:member(Action, [<<"issue">>, <<"send">>, <<"paid">>, <<"void">>]) of
        true -> {action, valid_id(Id), Action, M};
        false -> throw(not_found)
    end;
route(<<"GET">>, [<<"admins">>], _) -> list_admins;
route(<<"POST">>, [<<"admins">>], M) -> {set_admin, M};
route(_, _, _) -> throw(not_found).
valid_id(Id) -> damage_invoice_model:id(Id).
body_id(M) -> valid_id(maps:get(<<"id">>, M, <<>>)).
matching_id(Id, M) ->
    case maps:get(<<"id">>, M, Id) =:= Id of
        true -> valid_id(Id);
        false -> throw({validation, <<"Body ID does not match the URL">>})
    end.
success_code({action, _, <<"issue">>, _}) -> 202;
success_code({action, _, <<"send">>, _}) -> 202;
success_code(_) -> 200.

read_json(Req0) ->
    ContentType = cowboy_req:header(<<"content-type">>, Req0, <<>>),
    case binary:split(ContentType, <<";">>) of
        [<<"application/json">> | _] -> ok;
        _ -> throw({http, 415, <<"Content-Type must be application/json">>, Req0})
    end,
    {Raw, Req} = read_body(Req0, [], 0),
    try jsx:decode(Raw, [return_maps]) of
        M when is_map(M) -> {M, Req};
        _ -> throw({http, 400, <<"Expected a JSON object">>, Req})
    catch error:_ -> throw({http, 400, <<"Invalid JSON">>, Req}) end.
read_body(Req0, Acc, Size) ->
    case cowboy_req:read_body(Req0, #{length => 65536, period => 5000}) of
        {Tag, Chunk, Req} when Tag =:= ok; Tag =:= more ->
            Total = Size + byte_size(Chunk),
            case Total =< ?MAX_BODY of
                false -> throw({http, 413, <<"Invoice request exceeds 256 KiB">>, Req});
                true -> case Tag of
                    ok -> {iolist_to_binary(lists:reverse([Chunk | Acc])), Req};
                    more -> read_body(Req, [Chunk | Acc], Total)
                end
            end
    end.
headers() ->
    #{<<"content-type">> => <<"application/json; charset=utf-8">>,
      <<"cache-control">> => <<"no-store, private">>, <<"pragma">> => <<"no-cache">>,
      <<"vary">> => <<"Authorization">>, <<"x-content-type-options">> => <<"nosniff">>,
      <<"referrer-policy">> => <<"no-referrer">>}.
error_body(Msg) -> #{status => <<"error">>, message => Msg}.
json(Code, Data, Req) -> cowboy_req:reply(Code, headers(), jsx:encode(Data), Req).
