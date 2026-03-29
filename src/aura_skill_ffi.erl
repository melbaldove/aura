-module(aura_skill_ffi).
-export([run_command/3]).

run_command(Command, Args, TimeoutMs) ->
    try
        Port = open_port({spawn_executable, binary_to_list(Command)},
                         [{args, [binary_to_list(A) || A <- Args]},
                          exit_status, binary, stderr_to_stdout]),
        collect_output(Port, <<>>, TimeoutMs)
    catch
        _:Reason ->
            {error, list_to_binary(io_lib:format("~p", [Reason]))}
    end.

collect_output(Port, Acc, TimeoutMs) ->
    receive
        {Port, {data, Data}} ->
            collect_output(Port, <<Acc/binary, Data/binary>>, TimeoutMs);
        {Port, {exit_status, Status}} ->
            {ok, {Status, Acc, <<>>}}
    after TimeoutMs ->
        port_close(Port),
        {error, <<"timeout">>}
    end.
