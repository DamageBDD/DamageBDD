%% Back-pressured HTTPS downloads. No shell commands or Python runtime.
-module(erm_model_http).
-export([fetch/4]).
fetch(File,Path,Progress,Timeout) ->
    {ok,_}=application:ensure_all_started(inets),
    {ok,_}=application:ensure_all_started(ssl),
    {ok,F}=file:open(Path,[write,binary,raw,exclusive]),
    try
        Hash=request(maps:get(url,File),F,File,Progress,Timeout,5),
        true = Hash =:= maps:get(sha256,File),
        ok=file:sync(F),ok
    catch
        error:{badmatch,false}->error(checksum_mismatch)
    after file:close(F) end.
request(Url,F,File,Progress,Timeout,Redirects) when Redirects>=0 ->
    #{scheme:="https",host:=Host}=Parsed=uri_string:parse(Url),
    false=maps:is_key(userinfo,Parsed),
    SSL=[{verify,verify_peer},{cacerts,public_key:cacerts_get()},
         {server_name_indication,Host},
         {customize_hostname_check,[{match_fun,public_key:pkix_verify_hostname_match_fun(https)}]}],
    Http=[{ssl,SSL},{autoredirect,false},{connect_timeout,15000},{timeout,Timeout}],
    {ok,Id}=httpc:request(get,{Url,[{"accept-encoding","identity"}]},Http,
                         [{sync,false},{stream,{self,once}}]),
    Owner=self(),Guard=spawn(fun()->
        M=monitor(process,Owner),
        receive done->demonitor(M,[flush]);{'DOWN',M,process,Owner,_}->httpc:cancel_request(Id) end
    end),
    try receive
        {http,{Id,stream_start,Headers,Handler}} ->
            %% We never request ranges; reject unsolicited partial responses.
            false=lists:keymember("content-range",1,Headers),
            httpc:stream_next(Handler),
            stream(Id,Handler,F,File,Progress,Timeout,0,crypto:hash_init(sha256),0);
        {http,{Id,{{_,Code,_},Headers,_}}} when Code=:=301;Code=:=302;Code=:=303;Code=:=307;Code=:=308 ->
            {"location",Location}=lists:keyfind("location",1,Headers),
            request(uri_string:resolve(Location,Url),F,File,Progress,Timeout,Redirects-1);
        {http,{Id,{{_,Code,_},_,_}}}->error({http_status,Code});
        {http,{Id,{error,R}}}->error({http_request_failed,network_reason(R)})
    after Timeout ->error(download_timeout)
    end after httpc:cancel_request(Id),Guard!done end;
request(_,_,_,_,_,_)->error(too_many_redirects).
stream(Id,H,F,Spec,Progress,Timeout,N,Hash,Reported)->
    receive
        {http,{Id,stream,B}} ->
            Next=N+byte_size(B),
            case Next=<maps:get(bytes,Spec) of true->ok;false->error(size_limit_exceeded) end,
            ok=file:write(F,B),
            R=case Next-Reported>=1048576 of true->Progress(Next),Next;false->Reported end,
            httpc:stream_next(H),
            stream(Id,H,F,Spec,Progress,Timeout,Next,crypto:hash_update(Hash,B),R);
        {http,{Id,stream_end,_}} ->
            case N=:=maps:get(bytes,Spec) of true->ok;false->error({size_mismatch,N}) end,
            Progress(N),hex(crypto:hash_final(Hash));
        {http,{Id,{error,R}}}->error({http_request_failed,network_reason(R)})
    after Timeout->error(download_timeout)
    end.
hex(B)->lists:flatten([io_lib:format("~2.16.0b",[X])||<<X>><=B]).

network_reason(R) when is_atom(R)->R;
network_reason({failed_connect,Details})->
    case lists:keyfind(inet,1,Details) of
        {inet,_,R}->network_reason(R);
        false->case lists:keyfind(inet6,1,Details) of
            {inet6,_,R}->network_reason(R);
            false->case lists:keyfind(tls,1,Details) of
                {tls,_,R}->network_reason(R);_->connect_failed
            end
        end
    end;
network_reason({tls_alert,{Alert,_}}) when is_atom(Alert)->{tls_alert,Alert};
network_reason(_)->request_failed.
