%% ----- Context holds ETS tables (opaque to callers) -----
-record(ctx, {
    % ETS ordered_set: {{TermBin, DocIdInt}} -> true
    post_tab,
    % ETS set: TermBin -> DF (int)
    df_tab,
    % ETS set: TermBin -> TermTag(any())  (ecai:hash_to_curve/1)
    tag_tab,
    % ETS set: TermBin -> RootBin(sha256 scheme)
    root_tab,
    % ETS set: DocIdBin -> #{terms:= [TermBin], data:= map(), int:= DocIdInt}
    rec_tab,
    % ETS set: DocIdInt -> DocIdBin
    id2doc_tab,
    % ETS set: DocIdBin -> DocIdInt
    doc2id_tab,
    % ETS set: <<"seq">> -> NextInt
    next_id_tab,
    opts = #{
        % enable prefix terms
        prefix => true,
        % enable suffix terms (reversed)
        suffix => false,
        % 0=off, else 2 or 3 is typical
        infix_n => 0,
        % enable per-field expansion
        fields => #{
            name => #{prefix => true, suffix => true, infix => true},
            city => #{prefix => true, suffix => false, infix => false},
            cat => #{prefix => false, suffix => false, infix => false},
            tag => #{prefix => false, suffix => false, infix => false},
            phone => #{prefix => true, suffix => false, infix => false}
        }
    },
    %% ets | gpu
    backend = ets,
    %% NIF resource handle
    gpu = undefined,
    dyn = undefined,
    next_tid = 0,
    %% #{TermBin => Tid :: non_neg_integer()}
    term_ids = #{}
}).
