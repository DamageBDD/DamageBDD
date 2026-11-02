%% Opt-in node-local STT for chat. Never takes backend URLs from callers.
-module(ecai_voice_notes_http).
-license("Apache-2.0").
-export([trails/0, init/2]).

-define(MAX_BYTES, 2097152).

trails() -> [
    trails:trail("/ecai/voice-notes/transcribe", ?MODULE, #{action => transcribe},
        #{post => #{tags => ["ECAI Voice"], produces => ["application/json"]}})
].

init(Req0, _Opts) ->
    case {cowboy_req:method(Req0), authenticated(Req0), same_origin(Req0)} of
        {<<"POST">>, true, true} -> transcribe(Req0);
        {<<"POST">>, false, _} -> reply(Req0, 401, #{ok => false, error => unauthorized});
        {<<"POST">>, _, false} -> reply(Req0, 403, #{ok => false, error => bad_origin});
        _ -> reply(Req0, 405, #{ok => false, error => method_not_allowed})
    end.

authenticated(Req) ->
    %% Reuse the same Bearer token validation as conversation and knowledge HTTP.
    case cowboy_req:header(<<"authorization">>, Req, undefined) of
        <<"Bearer ", Token/binary>> when byte_size(Token) >= 10, byte_size(Token) =< 8192 ->
            try
                case damage_auth:resolve_oauth(Token, #{}) of
                    {ok, Auth} ->
                        case damage_auth:authenticated_account(Auth) of
                            {ok, Owner} when is_binary(Owner), byte_size(Owner) > 0 -> true;
                            _ -> false
                        end;
                    _ -> false
                end
            catch _:_ -> false end;
        _ -> false
    end.

same_origin(Req) ->
    case cowboy_req:header(<<"origin">>, Req, undefined) of
        undefined -> true;
        Origin ->
            %% Reject obvious cross-site browser submissions; the Bearer token is
            %% also mandatory. Compare against Cowboy's canonical request host.
            Host = cowboy_req:host(Req),
            try
                case uri_string:parse(Origin) of
                    #{scheme := Scheme, host := OriginHost} ->
                        (Scheme =:= <<"https">> orelse Scheme =:= <<"http">>) andalso
                            string:lowercase(OriginHost) =:= string:lowercase(Host);
                    _ -> false
                end
            catch _:_ -> false end
    end.

transcribe(Req0) ->
    try
        case ecai_voice_notes:config() of
            {ok, #{enabled := true} = Config} ->
                Type = cowboy_req:header(<<"content-type">>, Req0, <<>>),
                Max = min(?MAX_BYTES, maps:get(max_audio_bytes, Config, ?MAX_BYTES)),
                case ecai_voice_notes:media_type(Type) of
                    {ok, Format} ->
                        Params = cowboy_req:match_qs([
                            {language, [], <<"en">>}, {cleanup, [], <<"0">>}
                        ], Req0),
                        Language = maps:get(language, Params),
                        Cleanup = maps:get(cleanup, Params),
                        case ecai_voice_notes:request_options(Language, Cleanup) of
                            {ok, Options} ->
                                case read_body(Req0, <<>>, Max) of
                                    {ok, Bytes, Req1} ->
                                        case ecai_voice_notes:transcribe(Bytes, Format, Options) of
                                            {ok, Result} -> reply(Req1, 200, #{ok => true, result => Result});
                                            {error, E} -> fail(Req1, E)
                                        end;
                                    {error, E, Req1} -> fail(Req1, E)
                                end;
                            Error -> fail(Req0, element(2, Error))
                        end;
                    {error, E} -> fail(Req0, E)
                end;
            {ok, _} -> fail(Req0, voice_disabled);
            {error, E} -> fail(Req0, E)
        end
    catch _:_ -> fail(Req0, transcription_unavailable) end.

read_body(Req0, Acc, Max) ->
    case cowboy_req:read_body(Req0, #{length => Max, period => 15000}) of
        {ok, B, Req1} ->
            Out = <<Acc/binary, B/binary>>,
            if byte_size(Out) =< Max -> {ok, Out, Req1};
               true -> {error, body_too_large, Req1}
            end;
        {more, B, Req1} ->
            Out = <<Acc/binary, B/binary>>,
            if byte_size(Out) =< Max -> read_body(Req1, Out, Max);
               true -> {error, body_too_large, Req1}
            end
    end.

fail(Req, Error) ->
    Status = case Error of
        invalid_request -> 400;
        invalid_audio -> 400;
        unsupported_media_type -> 415;
        body_too_large -> 413;
        audio_too_long -> 413;
        no_speech -> 422;
        voice_busy -> 429;
        transcription_timeout -> 504;
        _ -> 503
    end,
    reply(Req, Status, #{ok => false, error => Error}).

reply(Req, Status, Data) ->
    Headers = #{<<"content-type">> => <<"application/json; charset=utf-8">>,
                <<"cache-control">> => <<"no-store">>,
                <<"x-content-type-options">> => <<"nosniff">>},
    {ok, cowboy_req:reply(Status, Headers, jsx:encode(Data), Req), #{}}.
