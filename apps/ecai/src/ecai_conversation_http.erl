%%%-------------------------------------------------------------------
%%% Authenticated conversation/project API for the ECAI dashboard.
%%% Anonymous chat remains on /ecai/chat; durable history never accepts an
%%% owner from the browser and is always scoped to the authenticated principal.
%%%-------------------------------------------------------------------
-module(ecai_conversation_http).

-export([
    trails/0,
    init/2,
    is_authorized/2,
    allowed_methods/2,
    content_types_accepted/2,
    content_types_provided/2,
    from_json/2,
    to_json/2,
    delete_resource/2
]).

-define(TAG, ["ECAI Conversations"]).
-define(MAX_BODY_BYTES, 65536).
-define(MAX_MESSAGE_BYTES, 16384).

trails() ->
    [
        trail("/ecai/conversations", conversations, #{
            get => op("List authenticated conversation history."),
            post => op("Create a durable ECAI conversation.")
        }),
        trail("/ecai/conversations/search", conversation_search, #{
            post => op("Search private conversation history with the ECAI term index.")
        }),
        trail("/ecai/conversations/personalities", conversation_personalities, #{
            get => op("List the default and this account's purchased AI personalities.")
        }),
        trail("/ecai/conversations/:id", conversation, #{
            get => op("Load one authenticated conversation and its messages."),
            patch => op("Rename, move, pin or archive a conversation."),
            delete => op("Delete a conversation and its private search postings.")
        }),
        trail("/ecai/conversations/:id/messages", conversation_message, #{
            post => op("Send a message using durable conversation/project context.")
        }),
        trail("/ecai/projects", projects, #{
            get => op("List ECAI conversation projects."),
            post => op("Create an ECAI conversation project.")
        }),
        trail("/ecai/projects/:id", project, #{
            get => op("Load one ECAI conversation project."),
            patch => op("Update project name or instructions."),
            delete => op("Delete a project while keeping its conversations unassigned.")
        })
    ].

trail(Path, Action, Methods) ->
    trails:trail(Path, ?MODULE, #{action => Action},
        maps:map(fun(_Method, Spec) ->
            Spec#{tags => ?TAG, consumes => ["application/json"], produces => ["application/json"]}
        end, Methods)).

op(Description) -> #{description => Description}.

init(Req, State) ->
    process_flag(sensitive, true),
    {cowboy_rest, Req, State}.

is_authorized(Req, State) ->
    damage_http:is_authorized(Req, State).

allowed_methods(Req, State = #{action := conversations}) ->
    {[<<"GET">>, <<"POST">>, <<"OPTIONS">>], Req, State};
allowed_methods(Req, State = #{action := conversation_search}) ->
    {[<<"POST">>, <<"OPTIONS">>], Req, State};
allowed_methods(Req, State = #{action := conversation_personalities}) ->
    {[<<"GET">>, <<"OPTIONS">>], Req, State};
allowed_methods(Req, State = #{action := conversation}) ->
    {[<<"GET">>, <<"PATCH">>, <<"DELETE">>, <<"OPTIONS">>], Req, State};
allowed_methods(Req, State = #{action := conversation_message}) ->
    {[<<"POST">>, <<"OPTIONS">>], Req, State};
allowed_methods(Req, State = #{action := projects}) ->
    {[<<"GET">>, <<"POST">>, <<"OPTIONS">>], Req, State};
allowed_methods(Req, State = #{action := project}) ->
    {[<<"GET">>, <<"PATCH">>, <<"DELETE">>, <<"OPTIONS">>], Req, State}.

content_types_accepted(Req, State) ->
    {[{{<<"application">>, <<"json">>, '*'}, from_json}], Req, State}.

content_types_provided(Req, State) ->
    {[{{<<"application">>, <<"json">>, []}, to_json}], Req, State}.

to_json(Req, State = #{action := Action}) ->
    with_principal(Req, State, fun(Principal) -> get_action(Action, Principal, Req) end).

from_json(Req0, State = #{action := Action}) ->
    with_principal(Req0, State, fun(Principal) ->
        case read_json(Req0) of
            {ok, Data, Req1} -> write_action(Action, Principal, Data, Req1);
            {error, payload_too_large, Req1} -> {error, payload_too_large, Req1};
            {error, invalid_json, Req1} -> {error, invalid_request, Req1}
        end
    end).

delete_resource(Req, State = #{action := Action}) ->
    with_principal(Req, State, fun(Principal) -> delete_action(Action, Principal, Req) end).

with_principal(Req, State, Fun) ->
    case authenticated_principal(State) of
        {ok, Principal} ->
            try Fun(Principal) of
                {ok, Status, Payload, Req1} -> reply_json(Status, Payload, Req1, State);
                {error, Reason, Req1} -> reply_error(Reason, Req1, State);
                {error, Reason} -> reply_error(Reason, Req, State)
            catch
                error:invalid_id -> reply_error(invalid_id, Req, State);
                error:empty_owner -> reply_error(unauthenticated, Req, State);
                throw:Reason -> reply_error(Reason, Req, State);
                Class:Reason:Stack ->
                    logger:warning("ECAI conversation request failed ~p:~p ~p", [Class, Reason, Stack]),
                    reply_error(conversation_operation_failed, Req, State)
            end;
        {error, _} ->
            reply_error(unauthenticated, Req, State)
    end.

get_action(conversation_personalities, Principal, Req) ->
    case ecai_personalities:owned_personalities(Principal) of
        {ok, #{items := Items}} when is_list(Items) ->
            Public = [maps:with([ref, personality_id, name, version, package_sha256], I)
                      || I <- Items, is_map(I)],
            {ok, 200, #{ok => true, items => Public}, Req};
        {error, Reason} -> {error, Reason, Req};
        _ -> {error, personality_unavailable, Req}
    end;
get_action(conversations, Principal, Req) ->
    ProjectId = qs_project(Req),
    Limit = qs_limit(Req, 50),
    case ecai_conversation_store:list_conversations(Principal, ProjectId, Limit) of
        {ok, Conversations} -> {ok, 200, #{ok => true, conversations => Conversations}, Req};
        {error, Reason} -> {error, Reason, Req}
    end;
get_action(conversation, Principal, Req) ->
    Id = cowboy_req:binding(id, Req),
    case ecai_conversation_store:get_conversation(Principal, Id) of
        {ok, #{conversation := Conversation, messages := Messages}} ->
            {ok, 200, #{ok => true, conversation => Conversation, messages => Messages}, Req};
        {error, Reason} -> {error, Reason, Req}
    end;
get_action(projects, Principal, Req) ->
    case ecai_conversation_store:list_projects(Principal) of
        {ok, Projects} -> {ok, 200, #{ok => true, projects => Projects}, Req};
        {error, Reason} -> {error, Reason, Req}
    end;
get_action(project, Principal, Req) ->
    Id = cowboy_req:binding(id, Req),
    case ecai_conversation_store:get_project(Principal, Id) of
        {ok, Project} -> {ok, 200, #{ok => true, project => Project}, Req};
        {error, Reason} -> {error, Reason, Req}
    end;
get_action(_, _Principal, Req) ->
    {error, method_not_allowed, Req}.

write_action(conversations, Principal, Data, Req) ->
    case only_keys(Data, [<<"project_id">>, <<"title">>, <<"personality_ref">>]) of
        true ->
            ProjectId = nullable_binary(maps:get(<<"project_id">>, Data, undefined)),
            Title = maps:get(<<"title">>, Data, <<>>),
            PersonalityRef = maps:get(<<"personality_ref">>, Data, <<"default">>),
            case is_binary(Title) of
                true ->
                    case ecai_conversation_store:create_conversation(
                        Principal, ProjectId, Title, PersonalityRef
                    ) of
                        {ok, Conversation} -> {ok, 201, #{ok => true, conversation => Conversation}, Req};
                        {error, Reason} -> {error, Reason, Req}
                    end;
                false -> {error, invalid_request, Req}
            end;
        false -> {error, invalid_request, Req}
    end;
write_action(conversation_search, Principal, Data, Req) ->
    case {only_keys(Data, [<<"query">>, <<"project_id">>, <<"limit">>]), maps:get(<<"query">>, Data, undefined)} of
        {true, Query} when is_binary(Query), byte_size(Query) > 0 ->
            ProjectId = nullable_binary(maps:get(<<"project_id">>, Data, undefined)),
            Limit = integer_value(maps:get(<<"limit">>, Data, 50), 50),
            case ecai_conversation_store:search(Principal, Query, ProjectId, Limit) of
                {ok, Results} -> {ok, 200, #{ok => true, results => Results}, Req};
                {error, Reason} -> {error, Reason, Req}
            end;
        _ -> {error, invalid_query, Req}
    end;
write_action(conversation, Principal, Data, Req) ->
    Id = cowboy_req:binding(id, Req),
    case conversation_patch(Data) of
        {ok, Patch} ->
            case ecai_conversation_store:update_conversation(Principal, Id, Patch) of
                {ok, Conversation} -> {ok, 200, #{ok => true, conversation => Conversation}, Req};
                {error, Reason} -> {error, Reason, Req}
            end;
        {error, Reason} -> {error, Reason, Req}
    end;
write_action(conversation_message, Principal, Data, Req) ->
    Id = cowboy_req:binding(id, Req),
    case valid_message(Data) of
        {ok, Message, Indexes} -> send_persistent_message(Principal, Id, Message, Indexes, Req);
        {error, Reason} -> {error, Reason, Req}
    end;
write_action(projects, Principal, Data, Req) ->
    case {only_keys(Data, [<<"name">>, <<"instructions">>]), maps:get(<<"name">>, Data, undefined)} of
        {true, Name} when is_binary(Name), byte_size(Name) > 0 ->
            Instructions = maps:get(<<"instructions">>, Data, <<>>),
            case is_binary(Instructions) of
                true ->
                    case ecai_conversation_store:create_project(Principal, Name, Instructions) of
                        {ok, Project} -> {ok, 201, #{ok => true, project => Project}, Req};
                        {error, Reason} -> {error, Reason, Req}
                    end;
                false -> {error, invalid_request, Req}
            end;
        _ -> {error, invalid_request, Req}
    end;
write_action(project, Principal, Data, Req) ->
    Id = cowboy_req:binding(id, Req),
    case project_patch(Data) of
        {ok, Patch} ->
            case ecai_conversation_store:update_project(Principal, Id, Patch) of
                {ok, Project} -> {ok, 200, #{ok => true, project => Project}, Req};
                {error, Reason} -> {error, Reason, Req}
            end;
        {error, Reason} -> {error, Reason, Req}
    end;
write_action(_, _Principal, _Data, Req) ->
    {error, method_not_allowed, Req}.

delete_action(conversation, Principal, Req) ->
    Id = cowboy_req:binding(id, Req),
    case ecai_conversation_store:delete_conversation(Principal, Id) of
        {ok, Result} -> {ok, 200, maps:merge(#{ok => true}, Result), Req};
        {error, Reason} -> {error, Reason, Req}
    end;
delete_action(project, Principal, Req) ->
    Id = cowboy_req:binding(id, Req),
    case ecai_conversation_store:delete_project(Principal, Id) of
        {ok, Result} -> {ok, 200, maps:merge(#{ok => true}, Result), Req};
        {error, Reason} -> {error, Reason, Req}
    end;
delete_action(_, _Principal, Req) ->
    {error, method_not_allowed, Req}.

send_persistent_message(Principal, ConversationId, Message, Indexes, Req) ->
    %% Fail closed for unknown/unowned funded IDs before durable append.
    Authorization = case Indexes of
        all -> {ok, all};
        _ -> ecai_knowledge:authorize_indexes(Principal, Indexes)
    end,
    case Authorization of
        {ok, Canonical} ->
            ContextLimit = application:get_env(ecai, conversation_history_context_messages, 12),
            case ecai_conversation_store:context(Principal, ConversationId, Message, ContextLimit) of
                {error, Reason} -> {error, Reason, Req};
                {ok, Context} ->
                    PersonalityRef = maps:get(personality_ref, Context, <<"default">>),
                    case validate_personality(Principal, PersonalityRef) of
                        ok -> send_validated_message(Principal, ConversationId, Message,
                                                     Context, PersonalityRef, Canonical, Req);
                        {error, Reason} -> {error, Reason, Req}
                    end
            end;
        {error, Reason} -> {error, Reason, Req}
    end.

send_validated_message(Principal, ConversationId, Message, Context, PersonalityRef, Indexes, Req) ->
            History = maps:get(recent, Context, []) ++ maps:get(related, Context, []),
            Options = #{
                history_context => History,
                project_instructions => maps:get(project_instructions, Context, <<>>),
                personality_ref => PersonalityRef,
                indexes => Indexes,
                include_retrieval_meta => true,
                self_store => false
            },
            %% Persist the user turn before generation so a backend failure cannot
            %% silently erase what the user sent from durable history.
            case ecai_conversation_store:append_message(
                Principal, ConversationId, <<"user">>, Message, #{}
            ) of
                {error, Reason} ->
                    {error, Reason, Req};
                {ok, #{message := UserMessage}} ->
                    send_persistent_reply(
                        Principal, ConversationId, Message, UserMessage, Options, Req
                    )
            end.

validate_personality(Principal, Ref) when is_binary(Ref), byte_size(Ref) > 0,
                                        byte_size(Ref) =< 256 ->
    try ecai_personalities:resolve_personality(Principal, Ref) of
        {ok, #{ref := Ref}} -> ok;
        {error, Why} when Why =:= invalid_personality; Why =:= personality_not_owned;
                          Why =:= personality_unavailable -> {error, Why};
        _ -> {error, personality_unavailable}
    catch _:_ -> {error, personality_unavailable} end;
validate_personality(_, _) -> {error, invalid_personality}.

send_persistent_reply(Principal, ConversationId, Message, UserMessage, Options, Req) ->
    case ecai_otp_compat:catch_value(fun() ->
        ecai_chat:get_reply(ConversationId, Principal, Message, Options)
    end) of
        {ok, Reply0, SearchMeta} when is_map(SearchMeta) ->
            store_persistent_reply(Principal, ConversationId, Reply0,
                UserMessage, Options, SearchMeta, Req);
        {ok, Reply0} ->
            %% Compatibility for existing test doubles and unfiltered clients.
            %% An explicit scope must never be silently ignored by an old worker.
            case maps:get(indexes, Options, all) of
                all -> store_persistent_reply(Principal, ConversationId, Reply0,
                    UserMessage, Options, undefined, Req);
                _ -> {error, chat_unavailable, Req}
            end;
        {error, Reason} -> {error, {chat_failed, Reason}, Req};
        {'EXIT', Reason} -> {error, {chat_failed, Reason}, Req};
        Other -> {error, {chat_failed, Other}, Req}
    end.

store_persistent_reply(Principal, ConversationId, Reply0, UserMessage, Options, SearchMeta, Req) ->
    Reply = to_bin(Reply0),
    Meta0 = #{backend => <<"ecai_chat">>,
              personality_ref => maps:get(personality_ref, Options, <<"default">>)},
    Meta = case SearchMeta of
        #{selection := Selection} -> Meta0#{retrieval_selection => Selection};
        _ -> Meta0
    end,
    case ecai_conversation_store:append_message(Principal, ConversationId,
        <<"assistant">>, Reply, Meta) of
        {ok, #{conversation := Conversation, message := AssistantMessage}} ->
            Base = #{ok => true, reply => Reply, conversation => Conversation,
                user_message => UserMessage, assistant_message => AssistantMessage},
            Payload = case SearchMeta of
                #{selection := SearchSelection} -> Base#{retrieval => SearchMeta, selection => SearchSelection};
                _ -> Base
            end,
            {ok, 200, Payload, Req};
        {error, Reason} -> {error, Reason, Req}
    end.

conversation_patch(Data) when is_map(Data) ->
    case only_keys(Data, [<<"title">>, <<"project_id">>, <<"archived">>, <<"pinned">>,
                         <<"personality_ref">>]) of
        false -> {error, invalid_request};
        true ->
            try
                P0 = #{},
                P1 = maybe_binary(title, <<"title">>, Data, P0),
                P2 = case maps:find(<<"project_id">>, Data) of
                    {ok, V} -> P1#{project_id => nullable_binary(V)};
                    error -> P1
                end,
                P3 = maybe_boolean(archived, <<"archived">>, Data, P2),
                P4 = maybe_boolean(pinned, <<"pinned">>, Data, P3),
                P5 = maybe_binary(personality_ref, <<"personality_ref">>, Data, P4),
                case map_size(P5) of
                    0 -> {error, invalid_request};
                    _ -> {ok, P5}
                end
            catch
                throw:Reason -> {error, Reason}
            end
    end;
conversation_patch(_) -> {error, invalid_request}.

project_patch(Data) when is_map(Data) ->
    case only_keys(Data, [<<"name">>, <<"instructions">>]) of
        false -> {error, invalid_request};
        true ->
            try
                P0 = maybe_binary(name, <<"name">>, Data, #{}),
                P1 = maybe_binary(instructions, <<"instructions">>, Data, P0),
                case map_size(P1) of
                    0 -> {error, invalid_request};
                    _ -> {ok, P1}
                end
            catch
                throw:Reason -> {error, Reason}
            end
    end;
project_patch(_) -> {error, invalid_request}.

maybe_binary(AtomKey, BinaryKey, Data, Acc) ->
    case maps:find(BinaryKey, Data) of
        {ok, Value} when is_binary(Value) -> Acc#{AtomKey => Value};
        {ok, _} -> throw(invalid_request);
        error -> Acc
    end.

maybe_boolean(AtomKey, BinaryKey, Data, Acc) ->
    case maps:find(BinaryKey, Data) of
        {ok, Value} when is_boolean(Value) -> Acc#{AtomKey => Value};
        {ok, _} -> throw(invalid_request);
        error -> Acc
    end.

valid_message(#{<<"message">> := Message} = Data) when
    is_binary(Message), byte_size(Message) > 0, byte_size(Message) =< ?MAX_MESSAGE_BYTES ->
    case only_keys(Data, [<<"message">>, <<"indexes">>]) of
        true ->
            Input = maps:get(<<"indexes">>, Data, all),
            case Input of
                <<"all">> -> {ok, Message, all};
                _ -> case ecai_knowledge:validate_indexes(Input) of
                    {ok, Canonical} -> {ok, Message, Canonical};
                    Error -> Error
                end
            end;
        false -> {error, invalid_request}
    end;
valid_message(#{<<"message">> := Message}) when is_binary(Message), byte_size(Message) > ?MAX_MESSAGE_BYTES ->
    {error, message_too_large};
valid_message(_) -> {error, invalid_message}.

only_keys(Data, Allowed) when is_map(Data) ->
    lists:all(fun(Key) -> lists:member(Key, Allowed) end, maps:keys(Data));
only_keys(_, _) -> false.

nullable_binary(undefined) -> undefined;
nullable_binary(null) -> undefined;
nullable_binary(<<>>) -> undefined;
nullable_binary(Value) when is_binary(Value) -> Value;
nullable_binary(_) -> throw(invalid_request).

qs_project(Req) ->
    nullable_binary(qs_value(<<"project_id">>, Req, undefined)).

qs_limit(Req, Default) ->
    integer_value(qs_value(<<"limit">>, Req, integer_to_binary(Default)), Default).

qs_value(Key, Req, Default) ->
    proplists:get_value(Key, cowboy_req:parse_qs(Req), Default).

integer_value(Value, _Default) when is_integer(Value) -> Value;
integer_value(Value, Default) when is_binary(Value) ->
    try binary_to_integer(Value) catch _:_ -> Default end;
integer_value(_, Default) -> Default.

read_json(Req0) ->
    read_body(Req0, [], 0, erlang:monotonic_time(millisecond) + 15000).

read_body(Req0, Acc, Size, Deadline) ->
    Remaining = Deadline - erlang:monotonic_time(millisecond),
    case Remaining > 0 of
        false -> {error, invalid_json, Req0};
        true ->
            case cowboy_req:read_body(Req0, #{length => 65536, period => erlang:min(5000, Remaining)}) of
                {Status, Part, Req1} when Status =:= ok; Status =:= more ->
                    NewSize = Size + byte_size(Part),
                    case NewSize > ?MAX_BODY_BYTES of
                        true -> {error, payload_too_large, Req1};
                        false when Status =:= ok ->
                            Raw = iolist_to_binary(lists:reverse([Part | Acc])),
                            case ecai_otp_compat:catch_value(fun() -> jsx:decode(Raw, [return_maps]) end) of
                                Data when is_map(Data) -> {ok, Data, Req1};
                                _ -> {error, invalid_json, Req1}
                            end;
                        false -> read_body(Req1, [Part | Acc], NewSize, Deadline)
                    end
            end
    end.

authenticated_principal(State) ->
    case ecai_otp_compat:catch_value(fun() -> damage_auth:authenticated_account(State) end) of
        {ok, Owner} when is_binary(Owner), byte_size(Owner) > 0 -> {ok, Owner};
        _ ->
            case maps:get(ae_account, State, undefined) of
                #{public_key := Owner} when is_binary(Owner), byte_size(Owner) > 0 -> {ok, Owner};
                Owner when is_binary(Owner), byte_size(Owner) > 0 -> {ok, Owner};
                _ -> {error, unauthenticated}
            end
    end.

reply_error(Reason0, Req, State) ->
    Reason = public_reason(Reason0),
    reply_json(status(Reason), #{ok => false, error => reason_binary(Reason)}, Req, State).

public_reason({chat_failed, _}) -> chat_unavailable;
public_reason({unknown_fields, _}) -> invalid_request;
public_reason({unsupported_request, _}) -> invalid_request;
public_reason(Reason) when is_atom(Reason) -> Reason;
public_reason(_) -> conversation_operation_failed.

status(unauthenticated) -> 401;
status(forbidden) -> 403;
status(not_found) -> 404;
status(project_not_found) -> 404;
status(method_not_allowed) -> 405;
status(message_too_large) -> 413;
status(payload_too_large) -> 413;
status(invalid_request) -> 400;
status(invalid_personality) -> 400;
status(personality_not_owned) -> 403;
status(personality_unavailable) -> 503;
status(invalid_query) -> 400;
status(invalid_index_selection) -> 400;
status(funded_indexes_unavailable) -> 503;
status(knowledge_unavailable) -> 503;
status(invalid_message) -> 400;
status(empty_message) -> 400;
status(invalid_archived) -> 400;
status(invalid_pinned) -> 400;
status(invalid_id) -> 400;
status(empty_title) -> 400;
status(empty_project_name) -> 400;
status(project_instructions_too_large) -> 413;
status(chat_unavailable) -> 503;
status(_) -> 503.

reason_binary(Reason) when is_atom(Reason) -> atom_to_binary(Reason, utf8);
reason_binary(Other) -> iolist_to_binary(io_lib:format("~p", [Other])).

reply_json(Status, Payload, Req0, State) ->
    Req1 = cowboy_req:reply(Status, #{
        <<"content-type">> => <<"application/json">>,
        <<"cache-control">> => <<"no-store, private">>,
        <<"pragma">> => <<"no-cache">>,
        <<"x-content-type-options">> => <<"nosniff">>
    }, jsx:encode(Payload), Req0),
    {stop, Req1, State}.

to_bin(Bin) when is_binary(Bin) -> Bin;
to_bin(List) when is_list(List) -> unicode:characters_to_binary(List);
to_bin(Atom) when is_atom(Atom) -> atom_to_binary(Atom, utf8);
to_bin(Integer) when is_integer(Integer) -> integer_to_binary(Integer);
to_bin(Other) -> iolist_to_binary(io_lib:format("~p", [Other])).
