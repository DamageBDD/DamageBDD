%%%-------------------------------------------------------------------
%%% Durable, account-scoped ECAI conversation/project history.
%%%
%%% History is kept out of the public ECAI corpus.  Search uses the same
%%% canonical ecai_terms pipeline, but postings are scoped by authenticated
%%% owner and stored in local DETS files.
%%%-------------------------------------------------------------------
-module(ecai_conversation_store).
-behaviour(gen_server).

-export([
    start_link/0,
    list_conversations/3,
    create_conversation/3,
    get_conversation/2,
    update_conversation/3,
    delete_conversation/2,
    append_message/5,
    append_exchange/5,
    search/4,
    context/4,
    list_projects/1,
    create_project/3,
    get_project/2,
    update_project/3,
    delete_project/2
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(SERVER, ?MODULE).
-define(CONVERSATIONS, ecai_conversation_history_dets).
-define(MESSAGES, ecai_conversation_messages_dets).
-define(PROJECTS, ecai_conversation_projects_dets).
-define(POSTINGS, ecai_conversation_postings_dets).
-define(DEFAULT_LIMIT, 50).
-define(MAX_LIMIT, 100).
-define(MAX_TITLE_CHARS, 200).
-define(MAX_PROJECT_NAME_CHARS, 120).
-define(MAX_INSTRUCTIONS_BYTES, 8192).
-define(MAX_MESSAGE_BYTES, 16384).

-record(state, {
    conversations,
    messages,
    projects,
    postings,
    dir
}).

%%%===================================================================
%%% API
%%%===================================================================

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

list_conversations(Owner, ProjectId, Limit) ->
    call({list_conversations, owner(Owner), project_id(ProjectId), clamp_limit(Limit)}).

create_conversation(Owner, ProjectId, Title) ->
    call({create_conversation, owner(Owner), project_id(ProjectId), normalize_title(Title)}).

get_conversation(Owner, ConversationId) ->
    call({get_conversation, owner(Owner), id(ConversationId)}).

update_conversation(Owner, ConversationId, Patch) when is_map(Patch) ->
    call({update_conversation, owner(Owner), id(ConversationId), Patch}).

delete_conversation(Owner, ConversationId) ->
    call({delete_conversation, owner(Owner), id(ConversationId)}).

append_message(Owner, ConversationId, Role0, Content0, Meta) when is_map(Meta) ->
    Role = normalize_role(Role0),
    Content = normalize_message(Content0),
    call({append_message, owner(Owner), id(ConversationId), Role, Content, Meta}).

append_exchange(Owner, ConversationId, Question0, Answer0, Meta) when is_map(Meta) ->
    Question = normalize_message(Question0),
    Answer = normalize_message(Answer0),
    call({append_exchange, owner(Owner), id(ConversationId), Question, Answer, Meta}).

search(Owner, Query, ProjectId, Limit) ->
    call({search, owner(Owner), normalize_query(Query), project_id(ProjectId), clamp_limit(Limit)}).

context(Owner, ConversationId, Query, Limit) ->
    call({context, owner(Owner), id(ConversationId), normalize_query(Query), clamp_context_limit(Limit)}).

list_projects(Owner) ->
    call({list_projects, owner(Owner)}).

create_project(Owner, Name, Instructions) ->
    call({create_project, owner(Owner), normalize_project_name(Name), normalize_instructions(Instructions)}).

get_project(Owner, ProjectId) ->
    call({get_project, owner(Owner), id(ProjectId)}).

update_project(Owner, ProjectId, Patch) when is_map(Patch) ->
    call({update_project, owner(Owner), id(ProjectId), Patch}).

delete_project(Owner, ProjectId) ->
    call({delete_project, owner(Owner), id(ProjectId)}).

call(Request) ->
    gen_server:call(?SERVER, Request, 30000).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
    Dir0 = application:get_env(ecai, conversation_history_dir,
        filename:join(ecai_paths:runtime_dir(), "conversations")),
    Dir = path_list(Dir0),
    ok = ecai_paths:ensure_dir(Dir),
    _ = file:change_mode(Dir, 8#700),
    {ok, Conversations} = open_table(?CONVERSATIONS, filename:join(Dir, "conversations.dets"), set),
    {ok, Messages} = open_table(?MESSAGES, filename:join(Dir, "messages.dets"), set),
    {ok, Projects} = open_table(?PROJECTS, filename:join(Dir, "projects.dets"), set),
    {ok, Postings} = open_table(?POSTINGS, filename:join(Dir, "postings.dets"), bag),
    {ok, #state{
        conversations = Conversations,
        messages = Messages,
        projects = Projects,
        postings = Postings,
        dir = Dir
    }}.

handle_call({list_conversations, Owner, ProjectId, Limit}, _From, State) ->
    {reply, {ok, list_conversations0(Owner, ProjectId, Limit, State)}, State};
handle_call({create_conversation, Owner, ProjectId, Title0}, _From, State) ->
    case ensure_project(Owner, ProjectId, State) of
        ok ->
            Now = now_ms(),
            ConversationId = new_id(),
            AutoTitle = Title0 =:= <<>>,
            Title = case AutoTitle of true -> <<"New chat">>; false -> Title0 end,
            Conversation = #{
                id => ConversationId,
                title => Title,
                auto_title => AutoTitle,
                project_id => ProjectId,
                created_at => Now,
                updated_at => Now,
                message_count => 0,
                archived => false,
                pinned => false
            },
            ok = dets:insert(State#state.conversations, {{Owner, ConversationId}, Conversation}),
            ok = reindex_title(Owner, Conversation, State),
            ok = sync([State#state.conversations, State#state.postings]),
            {reply, {ok, public_conversation(Conversation)}, State};
        {error, _} = Error ->
            {reply, Error, State}
    end;
handle_call({get_conversation, Owner, ConversationId}, _From, State) ->
    {reply, get_conversation0(Owner, ConversationId, State), State};
handle_call({update_conversation, Owner, ConversationId, Patch}, _From, State) ->
    Reply = update_conversation0(Owner, ConversationId, Patch, State),
    {reply, Reply, State};
handle_call({delete_conversation, Owner, ConversationId}, _From, State) ->
    {reply, delete_conversation0(Owner, ConversationId, State), State};
handle_call({append_message, Owner, ConversationId, Role, Content, Meta}, _From, State) ->
    {reply, append_message0(Owner, ConversationId, Role, Content, Meta, State), State};
handle_call({append_exchange, Owner, ConversationId, Question, Answer, Meta}, _From, State) ->
    {reply, append_exchange0(Owner, ConversationId, Question, Answer, Meta, State), State};
handle_call({search, Owner, Query, ProjectId, Limit}, _From, State) ->
    {reply, {ok, search0(Owner, Query, ProjectId, Limit, State)}, State};
handle_call({context, Owner, ConversationId, Query, Limit}, _From, State) ->
    {reply, context0(Owner, ConversationId, Query, Limit, State), State};
handle_call({list_projects, Owner}, _From, State) ->
    {reply, {ok, list_projects0(Owner, State)}, State};
handle_call({create_project, Owner, Name, Instructions}, _From, State) ->
    Now = now_ms(),
    ProjectId = new_id(),
    Project = #{
        id => ProjectId,
        name => Name,
        instructions => Instructions,
        created_at => Now,
        updated_at => Now
    },
    ok = dets:insert(State#state.projects, {{Owner, ProjectId}, Project}),
    ok = dets:sync(State#state.projects),
    {reply, {ok, public_project(Project)}, State};
handle_call({get_project, Owner, ProjectId}, _From, State) ->
    {reply, lookup_project(Owner, ProjectId, State), State};
handle_call({update_project, Owner, ProjectId, Patch}, _From, State) ->
    {reply, update_project0(Owner, ProjectId, Patch, State), State};
handle_call({delete_project, Owner, ProjectId}, _From, State) ->
    {reply, delete_project0(Owner, ProjectId, State), State};
handle_call(Request, _From, State) ->
    {reply, {error, {unsupported_request, Request}}, State}.

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{conversations = C, messages = M, projects = P, postings = I}) ->
    _ = dets:close(C),
    _ = dets:close(M),
    _ = dets:close(P),
    _ = dets:close(I),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Conversation lifecycle
%%%===================================================================

list_conversations0(Owner, ProjectId, Limit, #state{conversations = Conversations}) ->
    Rows = dets:match_object(Conversations, {{Owner, '_'}, '_'}),
    Visible = [
        public_conversation(Conversation)
        || {{Owner0, _Id}, Conversation} <- Rows,
           Owner0 =:= Owner,
           maps:get(archived, Conversation, false) =:= false,
           project_matches(ProjectId, Conversation)
    ],
    lists:sublist(sort_recent(Visible), Limit).

get_conversation0(Owner, ConversationId, State) ->
    case lookup_conversation(Owner, ConversationId, State) of
        {ok, Conversation} ->
            Messages = messages_for(Owner, ConversationId, State),
            {ok, #{conversation => public_conversation(Conversation), messages => Messages}};
        {error, _} = Error ->
            Error
    end.

update_conversation0(Owner, ConversationId, Patch, State) ->
    case lookup_conversation(Owner, ConversationId, State) of
        {error, _} = Error -> Error;
        {ok, Conversation0} ->
            case normalize_conversation_patch(Patch, Conversation0) of
                {error, _} = Error -> Error;
                {ok, Conversation1} ->
                    ProjectId = maps:get(project_id, Conversation1, undefined),
                    case ensure_project(Owner, ProjectId, State) of
                        ok ->
                            Conversation = Conversation1#{updated_at => now_ms()},
                            ok = dets:insert(State#state.conversations, {{Owner, ConversationId}, Conversation}),
                            ok = reindex_title(Owner, Conversation, State),
                            ok = sync([State#state.conversations, State#state.postings]),
                            {ok, public_conversation(Conversation)};
                        {error, _} = Error -> Error
                    end
            end
    end.

delete_conversation0(Owner, ConversationId, State) ->
    case lookup_conversation(Owner, ConversationId, State) of
        {error, _} = Error -> Error;
        {ok, _Conversation} ->
            ok = dets:delete(State#state.conversations, {Owner, ConversationId}),
            ok = dets:match_delete(State#state.messages, {{Owner, ConversationId, '_'}, '_'}),
            ok = dets:match_delete(State#state.postings, {{Owner, '_'}, ConversationId, '_'}),
            ok = sync([State#state.conversations, State#state.messages, State#state.postings]),
            {ok, #{deleted => ConversationId}}
    end.

append_message0(Owner, ConversationId, Role, Content, Meta, State) ->
    case lookup_conversation(Owner, ConversationId, State) of
        {error, _} = Error -> Error;
        {ok, Conversation0} ->
            Seq = maps:get(message_count, Conversation0, 0) + 1,
            Now = now_ms(),
            Message = message_map(ConversationId, Seq, Role, Content, Now, Meta),
            ok = dets:insert(State#state.messages, {{Owner, ConversationId, Seq}, Message}),
            ok = index_message(Owner, ConversationId, Seq, Content, State),
            Conversation1 = case Role of
                <<"user">> -> maybe_auto_title(Conversation0, Content);
                _ -> Conversation0
            end,
            Conversation = Conversation1#{message_count => Seq, updated_at => Now},
            ok = dets:insert(State#state.conversations, {{Owner, ConversationId}, Conversation}),
            case maps:get(title, Conversation, <<>>) =/= maps:get(title, Conversation0, <<>>) of
                true -> ok = reindex_title(Owner, Conversation, State);
                false -> ok
            end,
            ok = sync([State#state.conversations, State#state.messages, State#state.postings]),
            {ok, #{conversation => public_conversation(Conversation), message => Message}}
    end.

append_exchange0(Owner, ConversationId, Question, Answer, Meta, State) ->
    case append_message0(Owner, ConversationId, <<"user">>, Question, #{}, State) of
        {error, _} = Error -> Error;
        {ok, #{message := UserMessage}} ->
            case append_message0(Owner, ConversationId, <<"assistant">>, Answer, Meta, State) of
                {error, _} = Error -> Error;
                {ok, #{conversation := Conversation, message := AssistantMessage}} ->
                    {ok, #{
                        conversation => Conversation,
                        user_message => UserMessage,
                        assistant_message => AssistantMessage
                    }}
            end
    end.

message_map(ConversationId, Seq, Role, Content, CreatedAt, Meta) ->
    Base = #{
        id => <<ConversationId/binary, ":", (integer_to_binary(Seq))/binary>>,
        conversation_id => ConversationId,
        seq => Seq,
        role => Role,
        content => Content,
        created_at => CreatedAt
    },
    case map_size(Meta) of
        0 -> Base;
        _ -> Base#{meta => Meta}
    end.

messages_for(Owner, ConversationId, #state{messages = Messages}) ->
    Rows = dets:match_object(Messages, {{Owner, ConversationId, '_'}, '_'}),
    [Message || {{_Owner, _ConversationId, _Seq}, Message} <-
        lists:sort(fun({{_, _, A}, _}, {{_, _, B}, _}) -> A =< B end, Rows)].

%%%===================================================================
%%% Projects
%%%===================================================================

list_projects0(Owner, #state{projects = Projects, conversations = Conversations}) ->
    Rows = dets:match_object(Projects, {{Owner, '_'}, '_'}),
    Counts = project_counts(Owner, Conversations),
    Projects0 = [
        (public_project(Project))#{conversation_count => maps:get(maps:get(id, Project), Counts, 0)}
        || {{Owner0, _Id}, Project} <- Rows, Owner0 =:= Owner
    ],
    lists:sort(fun(A, B) ->
        {maps:get(name, A, <<>>), maps:get(id, A)} =< {maps:get(name, B, <<>>), maps:get(id, B)}
    end, Projects0).

update_project0(Owner, ProjectId, Patch, State) ->
    case lookup_project(Owner, ProjectId, State) of
        {error, _} = Error -> Error;
        {ok, Project0} ->
            case normalize_project_patch(Patch, Project0) of
                {error, _} = Error -> Error;
                {ok, Project1} ->
                    Project = Project1#{updated_at => now_ms()},
                    ok = dets:insert(State#state.projects, {{Owner, ProjectId}, Project}),
                    ok = dets:sync(State#state.projects),
                    {ok, public_project(Project)}
            end
    end.

delete_project0(Owner, ProjectId, State = #state{conversations = Conversations}) ->
    case lookup_project(Owner, ProjectId, State) of
        {error, _} = Error -> Error;
        {ok, _Project} ->
            Rows = dets:match_object(Conversations, {{Owner, '_'}, '_'}),
            Now = now_ms(),
            Moved = lists:foldl(fun
                ({{Owner0, ConversationId}, Conversation0}, Acc)
                    when Owner0 =:= Owner ->
                    case maps:get(project_id, Conversation0, undefined) of
                        ProjectId ->
                            Conversation = Conversation0#{project_id => undefined, updated_at => Now},
                            ok = dets:insert(Conversations, {{Owner, ConversationId}, Conversation}),
                            Acc + 1;
                        _ -> Acc
                    end;
                (_, Acc) -> Acc
            end, 0, Rows),
            ok = dets:delete(State#state.projects, {Owner, ProjectId}),
            ok = sync([State#state.projects, Conversations]),
            {ok, #{deleted => ProjectId, conversations_unassigned => Moved}}
    end.

project_counts(Owner, Conversations) ->
    Rows = dets:match_object(Conversations, {{Owner, '_'}, '_'}),
    lists:foldl(fun
        ({{Owner0, _Id}, Conversation}, Acc) when Owner0 =:= Owner ->
            case {maps:get(archived, Conversation, false), maps:get(project_id, Conversation, undefined)} of
                {false, ProjectId} when is_binary(ProjectId), ProjectId =/= <<>> ->
                    maps:update_with(ProjectId, fun(N) -> N + 1 end, 1, Acc);
                _ -> Acc
            end;
        (_, Acc) -> Acc
    end, #{}, Rows).

%%%===================================================================
%%% ECAI term index / search
%%%===================================================================

search0(_Owner, <<>>, _ProjectId, _Limit, _State) -> [];
search0(Owner, Query, ProjectId, Limit, State = #state{postings = Postings}) ->
    Terms = safe_query_terms(Query),
    Scores = lists:foldl(fun(Term, Acc0) ->
        Hits = dets:lookup(Postings, {Owner, Term}),
        lists:foldl(fun
            ({{Owner0, _Term0}, ConversationId, Seq}, Acc) when Owner0 =:= Owner ->
                Key = {ConversationId, Seq},
                maps:update_with(Key, fun(N) -> N + 1 end, 1, Acc);
            (_, Acc) -> Acc
        end, Acc0, Hits)
    end, #{}, Terms),
    BestByConversation = maps:fold(fun({ConversationId, Seq}, Score, Acc) ->
        case search_result(Owner, ConversationId, Seq, Score, ProjectId, State) of
            undefined -> Acc;
            Result -> keep_best_result(Result, Acc)
        end
    end, #{}, Scores),
    Results0 = maps:values(BestByConversation),
    Sorted = lists:sort(fun(A, B) ->
        ScoreA = maps:get(score, A, 0),
        ScoreB = maps:get(score, B, 0),
        case ScoreA =:= ScoreB of
            true -> maps:get(updated_at, A, 0) >= maps:get(updated_at, B, 0);
            false -> ScoreA > ScoreB
        end
    end, Results0),
    lists:sublist(Sorted, Limit).

search_result(Owner, ConversationId, Seq, Score, ProjectId, State) ->
    case lookup_conversation(Owner, ConversationId, State) of
        {ok, Conversation} ->
            case maps:get(archived, Conversation, false) orelse not project_matches(ProjectId, Conversation) of
                true -> undefined;
                false ->
                    Snippet = case Seq of
                        0 -> maps:get(title, Conversation, <<>>);
                        _ ->
                            case lookup_message(Owner, ConversationId, Seq, State) of
                                {ok, Message} -> maps:get(content, Message, <<>>);
                                _ -> <<>>
                            end
                    end,
                    #{
                        conversation_id => ConversationId,
                        title => maps:get(title, Conversation, <<"New chat">>),
                        project_id => json_project_id(maps:get(project_id, Conversation, undefined)),
                        message_seq => Seq,
                        score => Score,
                        snippet => truncate_chars(Snippet, 320),
                        updated_at => maps:get(updated_at, Conversation, 0)
                    }
            end;
        _ -> undefined
    end.

keep_best_result(Result, Acc) ->
    Id = maps:get(conversation_id, Result),
    case maps:get(Id, Acc, undefined) of
        undefined -> Acc#{Id => Result};
        Previous ->
            A = {maps:get(score, Result, 0), maps:get(message_seq, Result, 0)},
            B = {maps:get(score, Previous, 0), maps:get(message_seq, Previous, 0)},
            case A > B of
                true -> Acc#{Id => Result};
                false -> Acc
            end
    end.

reindex_title(Owner, Conversation, State = #state{postings = Postings}) ->
    ConversationId = maps:get(id, Conversation),
    ok = dets:match_delete(Postings, {{Owner, '_'}, ConversationId, 0}),
    Terms = safe_record_terms(#{
        title => maps:get(title, Conversation, <<>>),
        type => <<"conversation">>
    }),
    insert_postings(Owner, ConversationId, 0, Terms, State).

index_message(Owner, ConversationId, Seq, Content, State) ->
    Terms = safe_record_terms(#{
        text => Content,
        type => <<"conversation_message">>
    }),
    insert_postings(Owner, ConversationId, Seq, Terms, State).

insert_postings(Owner, ConversationId, Seq, Terms, #state{postings = Postings}) ->
    lists:foreach(fun(Term) ->
        ok = dets:insert(Postings, {{Owner, Term}, ConversationId, Seq})
    end, lists:usort(Terms)),
    ok.

safe_record_terms(Record) ->
    try ecai_terms:terms_from_record(Record) of
        Terms when is_list(Terms) -> Terms
    catch
        _:_ -> []
    end.

safe_query_terms(Query) ->
    try ecai_terms:terms_from_query(#{title => Query, text => Query}, true) of
        Terms when is_list(Terms) -> Terms
    catch
        _:_ -> []
    end.

%%%===================================================================
%%% Durable prompt context
%%%===================================================================

context0(Owner, ConversationId, Query, Limit, State) ->
    case lookup_conversation(Owner, ConversationId, State) of
        {error, _} = Error -> Error;
        {ok, Conversation} ->
            Current = recent_messages(Owner, ConversationId, Limit, State),
            ProjectId = maps:get(project_id, Conversation, undefined),
            Related0 = search0(Owner, Query, ProjectId, Limit, State),
            Related = related_messages(Owner, ConversationId, Related0, Limit, State),
            Instructions = project_instructions(Owner, ProjectId, State),
            {ok, #{
                recent => [history_record(M) || M <- Current],
                related => [history_record(M) || M <- Related],
                project_id => ProjectId,
                project_instructions => Instructions
            }}
    end.

recent_messages(Owner, ConversationId, Limit, State) ->
    Messages = messages_for(Owner, ConversationId, State),
    Count = length(Messages),
    Start = erlang:max(1, Count - Limit + 1),
    lists:nthtail(Start - 1, Messages).

related_messages(Owner, CurrentConversationId, Results, Limit, State) ->
    {_Seen, Messages} = lists:foldl(fun(Result, {Seen, Acc}) ->
        ConversationId = maps:get(conversation_id, Result),
        Seq = maps:get(message_seq, Result, 0),
        Key = {ConversationId, Seq},
        case ConversationId =:= CurrentConversationId orelse Seq =:= 0 orelse maps:is_key(Key, Seen) orelse length(Acc) >= Limit of
            true -> {Seen, Acc};
            false ->
                case lookup_message(Owner, ConversationId, Seq, State) of
                    {ok, Message} -> {Seen#{Key => true}, Acc ++ [Message]};
                    _ -> {Seen, Acc}
                end
        end
    end, {#{}, []}, Results),
    Messages.

history_record(Message) ->
    maps:with([conversation_id, seq, role, content, created_at], Message).

project_instructions(_Owner, undefined, _State) -> <<>>;
project_instructions(Owner, ProjectId, State) ->
    case lookup_project(Owner, ProjectId, State) of
        {ok, Project} -> maps:get(instructions, Project, <<>>);
        _ -> <<>>
    end.

%%%===================================================================
%%% Lookups / normalization
%%%===================================================================

lookup_conversation(Owner, ConversationId, #state{conversations = Conversations}) ->
    case dets:lookup(Conversations, {Owner, ConversationId}) of
        [{{Owner, ConversationId}, Conversation}] -> {ok, Conversation};
        [] -> {error, not_found};
        _ -> {error, corrupt_conversation_store}
    end.

lookup_message(Owner, ConversationId, Seq, #state{messages = Messages}) ->
    case dets:lookup(Messages, {Owner, ConversationId, Seq}) of
        [{{Owner, ConversationId, Seq}, Message}] -> {ok, Message};
        [] -> {error, not_found};
        _ -> {error, corrupt_message_store}
    end.

lookup_project(_Owner, undefined, _State) -> {error, not_found};
lookup_project(Owner, ProjectId, #state{projects = Projects}) ->
    case dets:lookup(Projects, {Owner, ProjectId}) of
        [{{Owner, ProjectId}, Project}] -> {ok, Project};
        [] -> {error, not_found};
        _ -> {error, corrupt_project_store}
    end.

ensure_project(_Owner, undefined, _State) -> ok;
ensure_project(Owner, ProjectId, State) ->
    case lookup_project(Owner, ProjectId, State) of
        {ok, _} -> ok;
        {error, not_found} -> {error, project_not_found};
        {error, _} = Error -> Error
    end.

normalize_conversation_patch(Patch, Conversation0) ->
    Allowed = [title, project_id, archived, pinned],
    case unknown_keys(Patch, Allowed) of
        [] ->
            try
                C1 = case maps:find(title, Patch) of
                    {ok, V} -> Conversation0#{title => normalize_required_title(V), auto_title => false};
                    error -> Conversation0
                end,
                C2 = case maps:find(project_id, Patch) of
                    {ok, V0} -> C1#{project_id => project_id(V0)};
                    error -> C1
                end,
                C3 = case maps:find(archived, Patch) of
                    {ok, V1} when is_boolean(V1) -> C2#{archived => V1};
                    {ok, _} -> throw(invalid_archived);
                    error -> C2
                end,
                C4 = case maps:find(pinned, Patch) of
                    {ok, V2} when is_boolean(V2) -> C3#{pinned => V2};
                    {ok, _} -> throw(invalid_pinned);
                    error -> C3
                end,
                {ok, C4}
            catch
                throw:Reason -> {error, Reason};
                error:Reason -> {error, Reason}
            end;
        Unknown -> {error, {unknown_fields, Unknown}}
    end.

normalize_project_patch(Patch, Project0) ->
    Allowed = [name, instructions],
    case unknown_keys(Patch, Allowed) of
        [] ->
            try
                P1 = case maps:find(name, Patch) of
                    {ok, V} -> Project0#{name => normalize_project_name(V)};
                    error -> Project0
                end,
                P2 = case maps:find(instructions, Patch) of
                    {ok, V0} -> P1#{instructions => normalize_instructions(V0)};
                    error -> P1
                end,
                {ok, P2}
            catch
                throw:Reason -> {error, Reason};
                error:Reason -> {error, Reason}
            end;
        Unknown -> {error, {unknown_fields, Unknown}}
    end.

unknown_keys(Map, Allowed) ->
    [K || K <- maps:keys(Map), not lists:member(K, Allowed)].

public_conversation(Conversation) ->
    Public0 = maps:without([auto_title], Conversation),
    Public0#{project_id => json_project_id(maps:get(project_id, Conversation, undefined))}.

json_project_id(undefined) -> null;
json_project_id(Value) -> Value.

public_project(Project) ->
    Project.

project_matches(undefined, _Conversation) -> true;
project_matches(ProjectId, Conversation) ->
    maps:get(project_id, Conversation, undefined) =:= ProjectId.

sort_recent(Conversations) ->
    lists:sort(fun(A, B) ->
        PinnedA = maps:get(pinned, A, false),
        PinnedB = maps:get(pinned, B, false),
        case PinnedA =:= PinnedB of
            false -> PinnedA andalso not PinnedB;
            true -> maps:get(updated_at, A, 0) >= maps:get(updated_at, B, 0)
        end
    end, Conversations).

maybe_auto_title(Conversation = #{auto_title := true}, Question) ->
    Conversation#{title => auto_title(Question)};
maybe_auto_title(Conversation, _Question) ->
    Conversation.

auto_title(Text) ->
    Clean = collapse_whitespace(Text),
    case truncate_chars(Clean, 72) of
        <<>> -> <<"New chat">>;
        Title -> Title
    end.

normalize_title(undefined) -> <<>>;
normalize_title(null) -> <<>>;
normalize_title(Value) -> truncate_chars(collapse_whitespace(to_bin(Value)), ?MAX_TITLE_CHARS).

normalize_required_title(Value) ->
    case normalize_title(Value) of
        <<>> -> throw(empty_title);
        Title -> Title
    end.

normalize_project_name(Value) ->
    Name = truncate_chars(collapse_whitespace(to_bin(Value)), ?MAX_PROJECT_NAME_CHARS),
    case Name of
        <<>> -> throw(empty_project_name);
        _ -> Name
    end.

normalize_instructions(undefined) -> <<>>;
normalize_instructions(null) -> <<>>;
normalize_instructions(Value) ->
    Bin = to_bin(Value),
    case byte_size(Bin) =< ?MAX_INSTRUCTIONS_BYTES of
        true -> Bin;
        false -> throw(project_instructions_too_large)
    end.

normalize_role(user) -> <<"user">>;
normalize_role(assistant) -> <<"assistant">>;
normalize_role(<<"user">>) -> <<"user">>;
normalize_role(<<"assistant">>) -> <<"assistant">>;
normalize_role(_) -> erlang:error(invalid_role).

normalize_message(Value) ->
    Bin = to_bin(Value),
    case {byte_size(Bin), collapse_whitespace(Bin)} of
        {0, _} -> throw(empty_message);
        {N, _} when N > ?MAX_MESSAGE_BYTES -> throw(message_too_large);
        {_, <<>>} -> throw(empty_message);
        _ -> Bin
    end.

normalize_query(Value) ->
    Bin = collapse_whitespace(to_bin(Value)),
    case byte_size(Bin) =< 4096 of
        true -> Bin;
        false -> truncate_bytes(Bin, 4096)
    end.

owner(Value) ->
    Bin = to_bin(Value),
    case Bin of
        <<>> -> erlang:error(empty_owner);
        _ -> Bin
    end.

id(Value) ->
    Bin = to_bin(Value),
    case valid_id(Bin) of
        true -> Bin;
        false -> erlang:error(invalid_id)
    end.

project_id(undefined) -> undefined;
project_id(null) -> undefined;
project_id(<<>>) -> undefined;
project_id(Value) -> id(Value).

valid_id(Bin) when is_binary(Bin), byte_size(Bin) =:= 32 ->
    lists:all(fun(C) ->
        (C >= $0 andalso C =< $9) orelse (C >= $a andalso C =< $f)
    end, binary_to_list(Bin));
valid_id(_) -> false.

clamp_limit(Value) when is_integer(Value) -> erlang:max(1, erlang:min(?MAX_LIMIT, Value));
clamp_limit(_) -> ?DEFAULT_LIMIT.

clamp_context_limit(Value) when is_integer(Value) -> erlang:max(1, erlang:min(24, Value));
clamp_context_limit(_) -> 12.

collapse_whitespace(Bin) ->
    List = unicode:characters_to_list(Bin),
    Trimmed = string:trim(List),
    unicode:characters_to_binary(string:join(string:tokens(Trimmed, " \t\r\n"), " ")).

truncate_chars(Bin, Max) ->
    Chars = unicode:characters_to_list(to_bin(Bin)),
    unicode:characters_to_binary(lists:sublist(Chars, Max)).

truncate_bytes(Bin, Max) when byte_size(Bin) =< Max -> Bin;
truncate_bytes(Bin, Max) ->
    Prefix = binary:part(Bin, 0, Max),
    case unicode:characters_to_binary(Prefix) of
        Result when is_binary(Result) -> Result;
        {incomplete, Valid, _Rest} -> Valid;
        {error, Valid, _Rest} -> Valid
    end.

new_id() ->
    Hex = binary:encode_hex(crypto:strong_rand_bytes(16)),
    << <<(lower_hex(C))>> || <<C>> <= Hex >>.

lower_hex(C) when C >= $A, C =< $F -> C + 32;
lower_hex(C) -> C.

now_ms() -> erlang:system_time(millisecond).

open_table(Name, Path, Type) ->
    ok = ecai_paths:ensure_parent(Path),
    Result = dets:open_file(Name, [{file, Path}, {type, Type}, {auto_save, 5000}]),
    case Result of
        {ok, Name} ->
            _ = file:change_mode(Path, 8#600),
            Result;
        _ -> Result
    end.

sync(Tables) ->
    lists:foreach(fun(Table) -> ok = dets:sync(Table) end, Tables),
    ok.

path_list(Bin) when is_binary(Bin) -> binary_to_list(Bin);
path_list(List) when is_list(List) -> List.

to_bin(Bin) when is_binary(Bin) -> Bin;
to_bin(List) when is_list(List) -> unicode:characters_to_binary(List);
to_bin(Atom) when is_atom(Atom) -> atom_to_binary(Atom, utf8);
to_bin(Integer) when is_integer(Integer) -> integer_to_binary(Integer);
to_bin(Other) -> iolist_to_binary(io_lib:format("~p", [Other])).
