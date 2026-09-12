%%% Bounded diagnostics. Never hand an original large term back to a logger.
-module(erm_lens_diagnostics).
-export([summary/1, stack/1, relay_label/1]).

summary(Term) ->
    %% chars_limit limits formatting work; depth alone does not bound binaries.
    try
        Text = io_lib:format("~P", [Term, 6], [{chars_limit, 1200}]),
        Chars = unicode:characters_to_list(Text),
        unicode:characters_to_binary(lists:sublist(Chars, 1200))
    catch
        _:_ -> <<"<unavailable diagnostic>">>
    end.

stack(Frames) when is_list(Frames) ->
    %% Stack frames may contain actual function arguments (URLs, keys, payloads).
    [mfa(F) || F <- lists:sublist(Frames, 6)];
stack(_) -> [].

mfa({M, F, Args, _}) when is_list(Args) -> {M, F, length(Args)};
mfa({M, F, Arity, _}) when is_integer(Arity) -> {M, F, Arity};
mfa(_) -> unknown.

relay_label(Url) ->
    %% No userinfo, query, path, or fragment in connection logs. Include a short
    %% digest so two endpoints at the same origin remain distinguishable.
    try
        B = unicode:characters_to_binary(Url),
        #{scheme := Scheme, host := Host} = U = uri_string:parse(B),
        true = byte_size(Host) =< 253,
        Port = maps:get(port, U, 443),
        Digest = binary:part(binary:encode_hex(crypto:hash(sha256, B)), 0, 12),
        iolist_to_binary([Scheme, "://", Host, ":", integer_to_binary(Port), "#", Digest])
    catch
        _:_ -> <<"<invalid relay URL>">>
    end.
