-module(ecai_nostr_content).

-export([
    build_event/2,
    prepare/2, prepare/3,
    publish/2, publish/3,
    publish_signed/1, publish_signed/2
]).

build_event(Pack, Media) when is_map(Pack), is_map(Media) ->
    Now = erlang:system_time(second),
    Title = bin(Pack, <<"title">>),
    Slug = bin(Pack, <<"slug">>),
    Summary = bin(Pack, <<"summary">>),
    Article = bin(Pack, <<"article_markdown">>),
    ImageUrl = ecai_content_util:to_binary(maps:get(url, Media, <<>>)),
    Topics0 = ecai_content_util:mget(<<"topics">>, Pack, []),
    TopicTags = [[<<"t">>, ecai_content_util:to_binary(T)] || T <- Topics0],
    BaseTags = [
        [<<"d">>, Slug],
        [<<"title">>, Title],
        [<<"summary">>, Summary],
        [<<"published_at">>, integer_to_binary(Now)]
    ],
    ImageTags =
        case ImageUrl of
            <<>> -> [];
            _ -> [[<<"image">>, ImageUrl]]
        end,
    #{
        kind => 30023,
        created_at => Now,
        content => Article,
        tags => BaseTags ++ ImageTags ++ TopicTags
    }.

prepare(Pack, Media) -> prepare(Pack, Media, #{}).

prepare(Pack, Media, Opts) when is_map(Opts) ->
    Event = build_event(Pack, Media),
    case ecai_nostr_signer:sign_event(Event, maps:get(signer, Opts, #{})) of
        {ok, Signed} -> {ok, Signed};
        {error, _} = Error -> Error
    end.

publish(Pack, Media) -> publish(Pack, Media, #{}).

publish(Pack, Media, Opts) when is_map(Opts) ->
    case prepare(Pack, Media, Opts) of
        {ok, Signed} -> publish_signed(Signed, Opts);
        {error, _} = Error -> Error
    end.

publish_signed(Signed) -> publish_signed(Signed, #{}).

publish_signed(Signed, Opts) when is_map(Signed), is_map(Opts) ->
    Relays = maps:get(relays, Opts, undefined),
    PublishResult =
        case Relays of
            undefined -> damage_nsecbunker_relay:publish_event(Signed);
            R when is_list(R) -> damage_nsecbunker_relay:publish_event(Signed, R)
        end,
    case PublishResult of
        {ok, Receipt} ->
            {ok, #{
                event_id => event_id(Signed),
                event => Signed,
                relay_receipt => Receipt
            }};
        {error, _} = Error ->
            Error;
        Other ->
            {ok, #{
                event_id => event_id(Signed),
                event => Signed,
                relay_receipt => Other
            }}
    end.

bin(Pack, Key) -> ecai_content_util:to_binary(ecai_content_util:mget(Key, Pack, <<>>)).

event_id(Event) ->
    ecai_content_util:to_binary(
        ecai_content_util:mget(<<"id">>, Event, ecai_content_util:mget(id, Event, <<>>))
    ).
