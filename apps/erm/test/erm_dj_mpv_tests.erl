%% Real ERM owner IPC against a local protocol fixture, not a fake player API.
%% Compile erm_mpv_proc with TEST (rebar3 eunit does this) to expose its boundary.
-module(erm_dj_mpv_tests).
-include_lib("eunit/include/eunit.hrl").

cached_audio_payload_test() ->
    {ok,Command}=erm_mpv_proc:cached_audio_command("/tmp/cache/song.mp3",<<"mp3">>),
    Packet=iolist_to_binary(erm_mpv_proc:encode_mpv_named_command(Command,42)),
    Request=jsx:decode(Packet,[return_maps]),
    ?assertMatch(#{<<"request_id">>:=42,<<"command">>:=#{<<"name">>:=<<"loadfile">>,
        <<"url">>:=<<"/tmp/cache/song.mp3">>,<<"flags">>:=<<"replace">>,
        <<"options">>:=#{<<"demuxer">>:=<<"lavf">>,<<"demuxer-lavf-format">>:=<<"mp3">>,
          <<"access-references">>:=<<"no">>,<<"autoload-files">>:=<<"no">>,
          <<"ytdl">>:=<<"no">>,<<"demuxer-lavf-o">>:=<<"protocol_whitelist=file">>}}},Request).

%% The real IPC roundtrip additionally runs wherever the host permits Unix
%% sockets. Some managed build sandboxes reject bind with eperm; the production
%% command builder/encoder and validation tests above still run in that case.
unix_fixture_test_() ->
    Path="/tmp/ecdj-mpv-probe-"++integer_to_list(erlang:unique_integer([positive,monotonic]))++".sock",
    case gen_tcp:listen(0,[{ifaddr,{local,Path}},binary,{active,false}]) of
        {ok,L}->gen_tcp:close(L),file:delete(Path),[fun cached_audio_ipc/0,fun legacy_and_failure_ipc/0];
        {error,eperm}->io:format("ECDJ IPC fixture unavailable: Unix sockets denied by host.~n",[]),[];
        {error,eacces}->io:format("ECDJ IPC fixture unavailable: Unix sockets denied by host.~n",[]),[]
    end.

cached_audio_ipc() ->
    {Result,Request}=with_socket(fun(Path)->
        erm_mpv_proc:direct_mpv_call(load_cached_audio,["/tmp/cache/song.mp3",<<"mp3">>],Path)
    end,<<"success">>),
    ?assertEqual({ok,ok},Result),
    #{<<"command">>:=Command}=Request,
    ?assertMatch(#{<<"name">>:=<<"loadfile">>,<<"url">>:=<<"/tmp/cache/song.mp3">>,<<"flags">>:=<<"replace">>},Command),
    Options=maps:get(<<"options">>,Command),
    ?assertEqual(<<"lavf">>,maps:get(<<"demuxer">>,Options)),
    ?assertEqual(<<"mp3">>,maps:get(<<"demuxer-lavf-format">>,Options)),
    ?assertEqual(<<"no">>,maps:get(<<"access-references">>,Options)),
    ?assertEqual(<<"no">>,maps:get(<<"autoload-files">>,Options)),
    ?assertEqual(<<"no">>,maps:get(<<"ytdl">>,Options)),
    ?assertEqual(<<"protocol_whitelist=file">>,maps:get(<<"demuxer-lavf-o">>,Options)).

owner_rejects_invalid_cached_audio_test() ->
    ?assertEqual({error,invalid_cached_audio},erm_mpv_proc:direct_mpv_call(load_cached_audio,["https://example.org/a.mp3",<<"mp3">>],"/nonexistent.sock")),
    ?assertEqual({error,invalid_cached_audio},erm_mpv_proc:direct_mpv_call(load_cached_audio,["relative.mp3",<<"mp3">>],"/nonexistent.sock")),
    ?assertEqual({error,invalid_cached_audio},erm_mpv_proc:direct_mpv_call(load_cached_audio,["/tmp/a.mp3",<<"hls">>],"/nonexistent.sock")).

legacy_and_failure_ipc() ->
    {Result,Request}=with_socket(fun(Path)->
        erm_mpv_proc:direct_mpv_call(load_file,["/tmp/normal.mp3"],Path)
    end,<<"success">>),
    ?assertEqual({ok,ok},Result),
    ?assertEqual([<<"loadfile">>,<<"/tmp/normal.mp3">>,<<"replace">>],maps:get(<<"command">>,Request)),
    {Failure,_}=with_socket(fun(Path)->
        erm_mpv_proc:direct_mpv_call(load_cached_audio,["/tmp/cache/song.flac",<<"flac">>],Path)
    end,<<"loading failed">>),
    ?assertEqual({error,{mpv_error,<<"loading failed">>,undefined}},Failure).

with_socket(Fun,Error) ->
    Path=filename:join("/tmp","ecdj-mpv-test-"++integer_to_list(erlang:unique_integer([positive,monotonic]))++".sock"),
    {ok,Listen}=gen_tcp:listen(0,[{ifaddr,{local,Path}},binary,{active,false},{packet,line}]),
    Parent=self(),Ref=make_ref(),
    {Worker,Monitor}=spawn_monitor(fun()->
        {ok,Socket}=gen_tcp:accept(Listen,2000),
        {ok,Line}=gen_tcp:recv(Socket,0,2000),
        Request=jsx:decode(Line,[return_maps]),
        ok=gen_tcp:send(Socket,[jsx:encode(#{<<"request_id">>=>maps:get(<<"request_id">>,Request),<<"error">>=>Error}),<<"\n">>]),
        Parent!{Ref,Request},gen_tcp:close(Socket)
    end),
    try
        Result=Fun(Path),
        receive
            {Ref,Request}->{Result,Request};
            {'DOWN',Monitor,process,Worker,Reason}->error({fixture_failed,Reason})
        after 3000->error(fixture_timeout)
        end
    after
        gen_tcp:close(Listen),file:delete(Path),exit(Worker,kill),erlang:demonitor(Monitor,[flush])
    end.
