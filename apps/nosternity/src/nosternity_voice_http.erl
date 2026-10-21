%% Voice requests use Nosternity's Nostr/Lightning/DamageBDD browser sessions.
%% No raw audio is indexed, retained, published, or accepted from anonymous users.
-module(nosternity_voice_http).
-export([trails/0, init/2]).

trails() -> [trails:trail(P, ?MODULE, #{action => A}, #{}) || {P, A} <- [
    {"/api/nosternity/voice/options", options},
    {"/api/nosternity/voice/transcribe", transcribe}]].

init(Req0, #{action := Action} = State) ->
    Req = nosternity_auth_http:no_store(Req0),
    try route(Action, Req) of R -> {ok, R, State}
    catch _:_ -> {ok, error_reply(transcription_unavailable, Req), State} end.

route(Action, Req) ->
    Method = case Action of options -> <<"GET">>; transcribe -> <<"POST">> end,
    case {cowboy_req:method(Req) =:= Method, nosternity_auth_http:allowed(Req)} of
        {false, _} -> error_reply(method_not_allowed,
            cowboy_req:set_resp_header(<<"allow">>, Method, Req));
        {_, false} -> error_reply(origin_rejected, Req);
        {true, true} ->
            %% Authorize before reading or decoding any upload.
            case nosternity_auth_http:session(Req) of
                {ok, Session} -> authorized(Action, Session, Req);
                _ -> error_reply(unauthorized, Req)
            end
    end.

authorized(options, _, Req) ->
    case ecai_voice_notes:options() of
        {ok, Options} -> reply(200, Options, Req);
        {error, Why} -> error_reply(Why, Req)
    end;
authorized(transcribe, Session, Req) ->
    case ecai_voice_notes:config() of
        {ok, #{enabled := false}} -> error_reply(voice_disabled, Req);
        {ok, C} ->
            Key = {voice_note, maps:get(provider, Session), maps:get(subject, Session)},
            case nosternity_auth:attempt(Key) of
                ok -> request(Session, C, Req);
                {error, Why} -> error_reply(Why, Req)
            end;
        {error, Why} -> error_reply(Why, Req)
    end.

request(Session, C, Req) ->
    Type = ecai_voice_notes:media_type(cowboy_req:header(<<"content-type">>, Req, <<>>)),
    Opts = ecai_voice_notes:request_options(cowboy_req:header(<<"x-voice-language">>, Req, <<"en">>),
        cowboy_req:header(<<"x-voice-cleanup">>, Req, <<"0">>)),
    case {Type, Opts, cowboy_req:header(<<"content-encoding">>, Req, <<"identity">>)} of
        {{ok, Media}, {ok, Options}, <<"identity">>} ->
            case read_body(Req, [], 0, maps:get(max_audio_bytes, C),
                    erlang:monotonic_time(millisecond) + 10000) of
                {ok, Audio, R} ->
                    Result = ecai_voice_notes:transcribe(Audio, Media, Options),
                    %% A logout/expiry while inference is running invalidates the response.
                    case nosternity_auth_http:session(R) of
                        {ok, Session} -> result(Result, R);
                        _ -> error_reply(unauthorized, R)
                    end;
                {error, Why, R} -> error_reply(Why, R)
            end;
        {{error, Why}, _, _} -> error_reply(Why, Req);
        {_, {error, Why}, _} -> error_reply(Why, Req);
        _ -> error_reply(unsupported_media_type, Req)
    end.

read_body(Req, Chunks, Size, Max, Deadline) ->
    Left = Deadline - erlang:monotonic_time(millisecond),
    case cowboy_req:body_length(Req) of
        Length when is_integer(Length), Length > Max -> {error, body_too_large, Req};
        _ when Left =< 0 -> {error, body_timeout, Req};
        _ ->
            case cowboy_req:read_body(Req, #{length => min(65536, Max - Size + 1),
                    period => min(2000, Left), timeout => Left + 1000}) of
                {Tag, Data, R} when Tag =:= ok; Tag =:= more ->
                    N = Size + byte_size(Data),
                    if
                        N > Max -> {error, body_too_large, R};
                        Tag =:= ok -> {ok, iolist_to_binary(lists:reverse([Data | Chunks])), R};
                        true -> read_body(R, [Data | Chunks], N, Max, Deadline)
                    end
            end
    end.

result({ok, Body}, R) -> reply(200, Body, R);
result({error, Why}, R) -> error_reply(Why, R).
error_reply(Why, Req) ->
    Status = case Why of
        unauthorized -> 401; origin_rejected -> 403; method_not_allowed -> 405;
        body_timeout -> 408; body_too_large -> 413; unsupported_media_type -> 415;
        no_speech -> 422; invalid_audio -> 422; audio_too_long -> 422;
        voice_busy -> 429; rate_limited -> 429;
        voice_disabled -> 503; voice_config_invalid -> 503; transcription_unavailable -> 503;
        transcription_timeout -> 504; _ -> 400
    end,
    R = case Status of 429 -> cowboy_req:set_resp_header(<<"retry-after">>, <<"5">>, Req); _ -> Req end,
    reply(Status, #{error => Why}, R).
reply(Code, Body, Req) -> nosternity_auth_http:reply(Code, Body, Req).
