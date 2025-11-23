-record(rec, {
  key,                 % binary()
  host = "127.0.0.1",
  port,                % integer()
  os_pid,              % OS pid int (from erlexec)
  exec_pid,            % erlang pid linked/monitored by erlexec
  user_data_dir,       % temp profile dir
  log_file             % chrome log
}).
