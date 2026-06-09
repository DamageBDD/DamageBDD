%%--------------------------------------------------------------------
%% ecai_log_index.erl
%% Minimal adapter. Replace body with your actual append/build logic.
%%--------------------------------------------------------------------
-module(ecai_log_index).
-export([add_doc/2]).

add_doc(_BaseDir, _Meta) ->
    %% Expected Meta:
    %% #{
    %%   cid => Fingerprint,
    %%   title => <<"log_event">>,
    %%   heading => <<"error">> | <<"warning">> | ...,
    %%   text => RawLine,
    %%   norm => NormalizedLine,
    %%   path => LogPath,
    %%   ts => Timestamp
    %% }
    %%
    %% Hook this into:
    %%   - ecai_disk_docstore append
    %%   - term extraction/tokenization on norm/text
    %%   - postings update / segment write
    ok.
