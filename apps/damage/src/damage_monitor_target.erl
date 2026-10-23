%% Explicitly scoped monitoring targets. No general-purpose proxy/URL fetch API.
-module(damage_monitor_target).
-license("Apache-2.0").
-export([parse_url/1, authorize/2, pin/2, address_allowed/2, tls_options/1]).

-spec parse_url(binary() | string()) -> {ok, map()} | {error, atom()}.
parse_url(Url0) when is_binary(Url0); is_list(Url0) ->
    try
        Url = unicode:characters_to_binary(Url0),
        true = byte_size(Url) > 0 andalso byte_size(Url) =< 2048,
        %% Reject Gherkin/template injection and ambiguous URL spellings.
        true = re:run(Url, <<"[\\x00-\\x20\\x7f\"'\\\\{}]">>, [{capture, none}]) =:= nomatch,
        #{scheme := Scheme, host := Host0} = P = uri_string:parse(Url),
        true = Scheme =:= <<"http">> orelse Scheme =:= <<"https">>,
        false = lists:any(fun(K) -> maps:is_key(K, P) end, [userinfo, query, fragment]),
        Host = string:lowercase(Host0),
        true = valid_host(Host),
        Port = maps:get(port, P, default_port(Scheme)),
        true = is_integer(Port) andalso Port >= 1 andalso Port =< 65535,
        Path = case maps:get(path, P, <<>>) of <<>> -> <<"/">>; V -> V end,
        true = byte_size(Path) =< 1024,
        true = re:run(Path, <<"^/[A-Za-z0-9_./~%:@!$&()*+,;=-]*$">>, [{capture, none}]) =:= match,
        %% Also reject encoded controls, quotes, braces and backslashes.
        Decoded = uri_string:percent_decode(Path),
        true = re:run(Decoded, <<"[\\x00-\\x20\\x7f\"'\\\\{}]">>, [{capture, none}]) =:= nomatch,
        AuthorityHost = case binary:match(Host, <<":">>) of
            nomatch -> Host;
            _ -> <<"[", Host/binary, "]">>
        end,
        Authority = case Port =:= default_port(Scheme) of
            true -> AuthorityHost;
            false -> <<AuthorityHost/binary, ":", (integer_to_binary(Port))/binary>>
        end,
        Origin = <<Scheme/binary, "://", Authority/binary>>,
        {ok, #{scheme => Scheme, host => Host, port => Port, path => Path,
            authority => Authority, origin => Origin, url => <<Origin/binary, Path/binary>>}}
    catch _:_ -> {error, invalid_monitor_url} end;
parse_url(_) -> {error, invalid_monitor_url}.

default_port(<<"https">>) -> 443;
default_port(<<"http">>) -> 80.

valid_host(Host) when byte_size(Host) > 0, byte_size(Host) =< 253 ->
    case inet:parse_strict_address(binary_to_list(Host)) of
        {ok, _IP} -> true;
        _ ->
            %% Single-label names are permitted only when explicitly configured
            %% by the operator; DNS ownership validation will otherwise fail.
            Labels = binary:split(Host, <<".">>, [global]),
            lists:all(fun valid_label/1, Labels) andalso
                re:run(lists:last(Labels), <<"[a-z]">>, [{capture, none}]) =:= match
    end;
valid_host(_) -> false.
valid_label(B) when byte_size(B) > 0, byte_size(B) =< 63 ->
    re:run(B, <<"^[a-z0-9]([a-z0-9-]*[a-z0-9])?$">>, [{capture, none}]) =:= match;
valid_label(_) -> false.

%% Exact owner + origin, not a suffix match, a UI flag, or the HTTP step's
%% localhost/developer-domain bypass. Configuration uses tuples/proplists.
-spec authorize(map(), binary()) -> ok | {error, atom()}.
authorize(#{origin := Origin, host := Host}, Owner) when is_binary(Owner), Owner =/= <<>> ->
    case configured(monitor_targets, Owner, Origin) orelse
        configured(monitor_private_targets, Owner, Origin) of
        true -> ok;
        false ->
            case ownership_lookup(binary_to_list(Host), Owner) of
                true -> ok;
                false -> {error, monitor_target_not_authorized}
            end
    end;
authorize(_, _) -> {error, monitor_target_not_authorized}.

ownership_lookup(Host, Owner) ->
    %% lookup_domain verifies this account's exact-host TXT proof. Bound the
    %% lookup, including its context-store call, without leaving a linked worker.
    {Pid, Ref} = spawn_monitor(fun() ->
        Result = try damage_domains:lookup_domain(Host, Owner) catch _:_ -> false end,
        exit({ownership_result, Result})
    end),
    receive
        {'DOWN', Ref, process, Pid, {ownership_result, true}} -> true;
        {'DOWN', Ref, process, Pid, _} -> false
    after 5000 ->
        exit(Pid, kill),
        receive {'DOWN', Ref, process, Pid, _} -> ok end,
        false
    end.

configured(Key, Owner, Origin) ->
    case application:get_env(damage, Key, []) of
        Entries when is_list(Entries) ->
            lists:any(fun
                ({O, U}) ->
                    case {to_binary(O), parse_url(U)} of
                        {Owner, {ok, #{origin := Origin, path := <<"/">>} = Target}} ->
                            valid_grant(Key, Target);
                        _ -> false
                    end;
                (_) -> false
            end, Entries);
        _ -> false
    end.

%% Private grants accept literal IP origins only. Authorizing a user-controlled
%% DNS name for arbitrary RFC1918 answers would permit rebinding inside a LAN.
valid_grant(monitor_private_targets, #{host := Host}) ->
    case inet:parse_strict_address(binary_to_list(Host)) of
        {ok, IP} -> private_address(IP) andalso address_allowed(IP, true);
        _ -> false
    end;
valid_grant(monitor_targets, _) -> true.

-spec pin(map(), binary()) -> {ok, map()} | {error, atom()}.
pin(#{host := Host, origin := Origin} = Target, Owner) ->
    Private = configured(monitor_private_targets, Owner, Origin),
    case addresses(Host) of
        [] -> {error, monitor_dns_failed};
        IPs ->
            case lists:all(fun(IP) -> address_allowed(IP, Private) end, IPs) of
                true -> {ok, Target#{ip => hd(IPs)}};
                false -> {error, monitor_destination_blocked}
            end
    end.

addresses(Host) ->
    H = binary_to_list(Host),
    case inet:parse_strict_address(H) of
        {ok, IP} -> [IP];
        _ ->
            try
                %% A/AAAA answers are checked together. Only the selected numeric
                %% address is ever passed to the transport (no second DNS lookup).
                lists:usort(inet_res:lookup(H, in, a, [], 3000) ++
                    inet_res:lookup(H, in, aaaa, [], 3000))
            catch _:_ -> [] end
    end.

-spec address_allowed(tuple(), boolean()) -> boolean().
address_allowed({168, 63, 129, 16}, _Private) -> false; %% Cloud platform virtual IP.
address_allowed({16#fd00, 16#ec2, 0, 0, 0, 0, 0, 16#254}, _Private) -> false;
address_allowed(IP, Private) ->
    public_address(IP) orelse (Private andalso private_address(IP)).

public_address({A, B, C, D} = IP) when
    is_integer(A), is_integer(B), is_integer(C), is_integer(D),
    A >= 0, B >= 0, C >= 0, D >= 0, A =< 255, B =< 255, C =< 255, D =< 255 ->
    damage_quickstart:public_ipv4(IP);
public_address({A, B, C, D, E, F, G, H} = IP) when
    is_integer(A), is_integer(B), is_integer(C), is_integer(D),
    is_integer(E), is_integer(F), is_integer(G), is_integer(H) ->
    lists:all(fun(N) -> N >= 0 andalso N =< 65535 end, tuple_to_list(IP)) andalso
        %% Only global-unicast 2000::/3; exclude protocol assignments, 6to4,
        %% documentation prefixes. This also rejects mapped/translated IPv4.
        (A band 16#e000) =:= 16#2000 andalso
        not (A =:= 16#2001 andalso (B < 16#0200 orelse B =:= 16#0db8)) andalso
        A =/= 16#2002 andalso
        not (A =:= 16#3fff andalso B < 16#1000);
public_address(_) -> false.

private_address({127, B, C, D}) -> octets([B, C, D]);
private_address({10, B, C, D}) -> octets([B, C, D]);
private_address({172, B, C, D}) when B >= 16, B =< 31 -> octets([C, D]);
private_address({192, 168, C, D}) -> octets([C, D]);
private_address({0, 0, 0, 0, 0, 0, 0, 1}) -> true;
private_address({A, B, C, D, E, F, G, H}) when (A band 16#fe00) =:= 16#fc00 ->
    lists:all(fun(N) -> is_integer(N) andalso N >= 0 andalso N =< 65535 end,
        [A, B, C, D, E, F, G, H]);
private_address(_) -> false.
octets(Ns) -> lists:all(fun(N) -> is_integer(N) andalso N >= 0 andalso N =< 255 end, Ns).

%% The transport connects to an IP but verifies the *original* DNS hostname.
%% For an IP literal, SSL's default IP certificate check is retained; never
%% use server_name_indication=disable, which would disable hostname checks.
tls_options(#{host := Host}) ->
    Base = damage_gun:tls_opts(binary_to_list(Host)),
    case inet:parse_strict_address(binary_to_list(Host)) of
        {ok, _} -> proplists:delete(server_name_indication, Base);
        _ -> Base
    end.
to_binary(V) when is_binary(V) -> V;
to_binary(V) when is_list(V) -> unicode:characters_to_binary(V);
to_binary(_) -> <<>>.
