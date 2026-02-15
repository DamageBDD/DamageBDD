-module(ecai_compress).
-author("Steven Joseph <steven@stevenjoseph.in>").
-license("Apache-2.0").

-export([compress/2]).

compress(#{ecai := true}, Text) when is_binary(Text); is_list(Text) ->
    {ok, Ref, _Count, _Point} = ecai_cache:get_ref(Text),
    {compressed, Ref};
compress(_, Text) ->
    {raw, Text}.
