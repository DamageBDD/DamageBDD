%%% @private
%%% Vanillae Request Manager for Erlang
%%%
%%% This process is responsible for remembering the configured nodes and dispatching
%%% requests to them. Request dispatch is made in a round-robin fashion with forwarded
%%% gen_server return `From' values passed to the request worker instead of being
%%% responded to directly by the manager itself (despite requests being generated as
%%% gen_server:call/3s.
%%% @end

-module(vanillae_man).
-vsn("0.4.1").
-behavior(gen_server).
-author("Craig Everett <ceverett@tsuriai.jp>").
-author("Steven Joseph <steven@stevenjoseph.in>").
-copyright("Craig Everett <ceverett@tsuriai.jp>").
-license("MIT").

-include_lib("kernel/include/logger.hrl").
%% Admin functions
-export([network_id/0, network_id/1,
         tls/0,        tls/1,
         ae_nodes/0,   ae_nodes/1,
         timeout/0,    timeout/1]).

%% The whole point of this module:
-export([request/1, request/2]).

%% gen_server goo
-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         code_change/3, terminate/2]).



%%% Type and Record Definitions

-record(fetcher,
        {pid  = none :: none | pid(),
         mon  = none :: none | reference(),
         time = none :: none | integer(), % nanosecond timestamp
         node = none :: none | vanillae:ae_node(),
         from = none :: none | gen_server:from(),
         req  = none :: none | binary()}).

-record(s,
        {network_id = "ae_mainnet" :: string(),
         tls        = false        :: boolean(),
         ae_nodes   = {[], []}     :: {[vanillae:ae_node()], [vanillae:ae_node()]},
         fetchers   = []           :: [#fetcher{}],
         timeout    = 5000         :: pos_integer()}).


-type state()   :: #s{}.



%%% Service Interface

-spec network_id() -> Name
    when Name :: vanillae:network_id().

network_id() ->
    gen_server:call(?MODULE, network_id).


-spec network_id(Name) -> ok
    when Name :: vanillae:network_id().

network_id(Name) ->
    gen_server:cast(?MODULE, {network_id, Name}).


-spec tls() -> boolean().

tls() ->
    gen_server:call(?MODULE, tls).


-spec tls(boolean()) -> ok.

tls(Boolean) ->
    gen_server:cast(?MODULE, {tls, Boolean}).


-spec ae_nodes() -> Used
    when Used :: [vanillae:ae_nodes()].

ae_nodes() ->
    gen_server:call(?MODULE, ae_nodes).


-spec ae_nodes(ToUse) -> ok
    when ToUse :: [vanillae:ae_nodes()].

ae_nodes(ToUse) ->
    gen_server:cast(?MODULE, {ae_nodes, ToUse}).


-spec timeout() -> Value
    when Value :: pos_integer().

timeout() ->
    gen_server:call(?MODULE, timeout).


-spec timeout(Value) -> ok
    when Value :: pos_integer().

timeout(Value) when 0 < Value, Value =< 120000 ->
    gen_server:cast(?MODULE, {timeout, Value}).


-spec request(Path) -> {ok, Value} | {error, Reason}
    when Path   :: unicode:charlist(),
         Value  :: map(),
         Reason :: vanillae:ae_error().

request(Path) ->
    gen_server:call(?MODULE, {request, {get, Path}}, infinity).


-spec request(Path, Data) -> {ok, Value} | {error, Reason}
    when Path   :: unicode:charlist(),
         Data   :: unicode:charlist(),
         Value  :: map(),
         Reason :: vanillae:ae_error().

request(Path, Data) ->
    gen_server:call(?MODULE, {request, {post, Path, Data}}, infinity).



%%% Startup Functions


-spec start_link() -> Result
    when Result :: {ok, pid()}
                 | {error, Reason :: term()}.
%% @private
%% This should only ever be called by v_clients (the service-level supervisor).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, none, []).


-spec init(none) -> {ok, state()}.
%% @private
%% Called by the supervisor process to give the process a chance to perform any
%% preparatory work necessary for proper function.

init(none) ->
    ok = io:format("Starting.~n"),
    State = #s{},
    {ok, State}.



%%% gen_server Message Handling Callbacks


handle_call({request, Request}, From, State) ->
    NewState = do_request(Request, From, State),
    {noreply, NewState};
handle_call(network_id, _, State = #s{network_id = Name}) ->
    {reply, Name, State};
handle_call(tls, _, State = #s{tls = TLS}) ->
    {reply, TLS, State};
handle_call(ae_nodes, _, State = #s{ae_nodes = {Wait, Used}}) ->
    Nodes = lists:append(Wait, Used),
    {reply, Nodes, State};
handle_call(timeout, _, State = #s{timeout = Value}) ->
    {reply, Value, State};
handle_call(Unexpected, From, State) ->
    ok = ?LOG_WARNING("Unexpected call from ~tp: ~tp~n", [From, Unexpected]),
    {noreply, State}.


handle_cast({network_id, Name}, State) ->
    {noreply, State#s{network_id = Name}};
handle_cast({tls, Boolean}, State) ->
    NewState = do_tls(Boolean, State),
    {noreply, NewState};
handle_cast({ae_nodes, []}, State) ->
    {noreply, State#s{ae_nodes = none}};
handle_cast({ae_nodes, ToUse}, State) ->
    {noreply, State#s{ae_nodes = {ToUse, []}}};
handle_cast({timeout, Value}, State) ->
    {noreply, State#s{timeout = Value}};
handle_cast(Unexpected, State) ->
    ok = ?LOG_WARNING("Unexpected cast: ~tp~n", [Unexpected]),
    {noreply, State}.


handle_info({'DOWN', Mon, process, PID, Info}, State) ->
    NewState = handle_down(PID, Mon, Info, State),
    {noreply, NewState};
handle_info(Unexpected, State) ->
    ok = ?LOG_WARNING("Unexpected info: ~tp~n", [Unexpected]),
    {noreply, State}.


handle_down(_, Mon, normal, State = #s{fetchers = Fetchers}) ->
    NewFetchers = lists:keydelete(Mon, #fetcher.mon, Fetchers),
    State#s{fetchers = NewFetchers};
handle_down(PID, Mon, Info, State = #s{fetchers = Fetchers}) ->
    case lists:keytake(Mon, #fetcher.mon, Fetchers) of
        {value, #fetcher{time = Time, node = Node, from = From, req = R}, Remaining} ->
            TS = calendar:system_time_to_rfc3339(Time, [{unit, nanosecond}]),
            Format =
                "ERROR ~ts: Fetcher process ~130tp exited while making request to ~130tp~n"
                "Exit reason:~n"
                "~tp~n"
                "Request contents:~n"
                "~tp~n~n",
            Formatted = io_lib:format(Format, [TS, PID, Node, Info, R]),
            Message = unicode:characters_to_list(Formatted),
            ok = gen_server:reply(From, {error, Message}),
            State#s{fetchers = Remaining};
        false ->
            Unexpected = {'DOWN', Mon, process, PID, Info},
            ok = ?LOG_WARNING(warning, "Unexpected info: ~w", [Unexpected]),
            State
    end.




%%% OTP Service Functions

code_change(_, State, _) ->
    {ok, State}.


terminate(_, _) ->
    ok.



%%% Doer Functions

do_tls(true, State) ->
    ok = ssl:start(),
    State#s{tls = true};
do_tls(false, State) ->
    State#s{tls = false};
do_tls(_, State) ->
    State.


do_request(_, From, State = #s{ae_nodes = {[], []}}) ->
    ok = gen_server:reply(From, {error, no_nodes}),
    State;
do_request(Request,
           From,
           State = #s{fetchers = Fetchers,
                      ae_nodes = {[Node | Rest], Used},
                      timeout  = Timeout,
                      tls      = TLS}) ->
    Now = erlang:system_time(nanosecond),
    Fetcher = fun() -> gun_fetch(Node, Request, From, Timeout, TLS) end,
    {PID, Mon} = spawn_monitor(Fetcher),
    New = #fetcher{pid  = PID,
                   mon  = Mon,
                   time = Now,
                   node = Node,
                   from = From,
                   req  = Request},
    State#s{fetchers = [New | Fetchers], ae_nodes = {Rest, [Node | Used]}};
do_request(Request, From, State = #s{ae_nodes = {[], Used}}) ->
    Fresh = lists:reverse(Used),
    do_request(Request, From, State#s{ae_nodes = {Fresh, []}}).

gun_fetch(Node, Request, From, Timeout, TLS) ->
    Reply =
        try
            gun_request(Node, Request, Timeout, TLS)
        catch
            Class:Reason:Stack ->
                {error, {gun_fetch_failed, Class, Reason, Stack}}
        end,
    ok = gen_server:reply(From, Reply).

gun_request(Node0, Request, Timeout, TLS) ->
    {Host, Port, PathPrefix} = normalize_node(Node0),
    Transport = transport_for_node(Port, TLS),
    Opts = gun_opts(Host, Transport),
    case damage_gun:open(Host, Port, Opts, none) of
        {ok, ConnPid} ->
            try
                case damage_gun:await_up(ConnPid, Timeout) of
                    {ok, _Protocol} ->
                        Path = request_path(PathPrefix, Request),
                        StreamRef = send_gun_request(ConnPid, Request, Path),
                        await_gun_response(ConnPid, StreamRef, Timeout);
                    Error ->
                        Error
                end
            after
                catch gun:close(ConnPid)
            end;
        Error ->
            Error
    end.

normalize_node({Host, Port, PathPrefix}) ->
    {Host, Port, PathPrefix};
normalize_node({Host, Port}) ->
    {Host, Port, "/"}.

transport_for_node(443, _TLS) -> tls;
transport_for_node(8443, _TLS) -> tls;
transport_for_node(_Port, true) -> tls;
transport_for_node(_Port, false) -> tcp.

gun_opts(_Host, tcp) ->
    #{transport => tcp};
gun_opts(Host, tls) ->
    #{transport => tls, tls_opts => damage_gun:tls_opts(Host)}.

request_path(PathPrefix, {get, Path}) ->
    join_path(PathPrefix, Path);
request_path(PathPrefix, {post, Path, _Data}) ->
    join_path(PathPrefix, Path).

send_gun_request(ConnPid, {get, _Path}, Path) ->
    gun:get(ConnPid, Path, default_headers());
send_gun_request(ConnPid, {post, _Path, Data}, Path) ->
    gun:post(ConnPid, Path, default_headers(), Data).

default_headers() ->
    [
        {<<"accept">>, <<"application/json">>},
        {<<"content-type">>, <<"application/json">>},
        {<<"user-agent">>, <<"vanillae-damagebdd/0.4.1">>}
    ].

await_gun_response(ConnPid, StreamRef, Timeout) ->
    case gun:await(ConnPid, StreamRef, Timeout) of
        {response, fin, Status, _Headers} ->
            decode_response(Status, <<>>);
        {response, nofin, Status, _Headers} ->
            case gun:await_body(ConnPid, StreamRef, Timeout) of
                {ok, Body} ->
                    decode_response(Status, Body);
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason};
        Other ->
            {error, {unexpected_gun_response, Other}}
    end.

json_decode(Body) ->
    normalize_json_decode(catch zj:binary_decode(Body), Body).

normalize_json_decode({ok, {ok, Json}}, _Body) ->
    {ok, normalize_json(Json)};

normalize_json_decode({ok, Json}, _Body) ->
    {ok, normalize_json(Json)};

normalize_json_decode(Json, _Body) ->
    {ok, normalize_json(Json)}.

join_path(Prefix0, Path0) ->
    Prefix = trim_trailing_slash(to_list(Prefix0)),
    Path = ensure_leading_slash(to_list(Path0)),
    case Prefix of
        "" -> Path;
        "/" -> Path;
        _ -> Prefix ++ Path
    end.

to_list(Bin) when is_binary(Bin) ->
    binary_to_list(Bin);
to_list(List) when is_list(List) ->
    lists:flatten(List).

ensure_leading_slash("/") ->
    "/";
ensure_leading_slash([$/ | _] = Path) ->
    Path;
ensure_leading_slash(Path) ->
    "/" ++ Path.

trim_trailing_slash("/") ->
    "/";
trim_trailing_slash(Path) ->
    string:trim(Path, trailing, "/").
decode_response(Status, Body) when Status >= 200, Status < 300 ->
    case Body of
        <<>> ->
            {ok, #{}};
        _ ->
            json_decode(Body)
    end;

decode_response(Status, Body) ->
    case json_decode(Body) of
        {ok, #{"reason" := Reason}} ->
            {error, Reason};
        {ok, Json} when is_map(Json) ->
            {error, Json};
        {ok, _} ->
            {error, {http_status, Status, Body}};
        Error ->
            Error
    end.
normalize_json(Json) when is_map(Json) ->
    maps:from_list([
        {normalize_json_key(K), normalize_json(V)}
        || {K, V} <- maps:to_list(Json)
    ]);

normalize_json(List) when is_list(List) ->
    [normalize_json(V) || V <- List];

normalize_json(Bin) when is_binary(Bin) ->
    binary_to_list(Bin);

normalize_json(V) ->
    V.

normalize_json_key(K) when is_binary(K) ->
    binary_to_list(K);
normalize_json_key(K) ->
    K.
