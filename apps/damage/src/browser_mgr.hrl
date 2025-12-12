-record(rec, {
    % binary()
    key,
    host = "127.0.0.1",
    % integer()
    port,
    % OS pid int (from erlexec)
    os_pid,
    % erlang pid linked/monitored by erlexec
    exec_pid,
    % temp profile dir
    user_data_dir,
    % chrome log
    log_file
}).
