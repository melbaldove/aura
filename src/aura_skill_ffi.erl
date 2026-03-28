-module(aura_skill_ffi).
-export([run_command/2]).

run_command(Command, Args) ->
    try
        Port = open_port({spawn_executable, binary_to_list(Command)},
                         [{args, [binary_to_list(A) || A <- Args]},
                          exit_status, binary, stderr_to_stdout]),
        collect_output(Port, <<>>)
    catch
        _:Reason ->
            {error, list_to_binary(io_lib:format("~p", [Reason]))}
    end.

collect_output(Port, Acc) ->
    receive
        {Port, {data, Data}} ->
            collect_output(Port, <<Acc/binary, Data/binary>>);
        {Port, {exit_status, Status}} ->
            {ok, {Status, Acc, <<>>}}
    after 30000 ->
        port_close(Port),
        {error, <<"timeout">>}
    end.
