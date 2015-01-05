-module(hm_process).
-export([least_busy_pid/1]).

least_busy_pid(Pids) ->
    Members = lists:map(fun(Pid) ->
        [
            {message_queue_len, Messages},
            {stack_size, StackSize}
        ] = erlang:process_info(Pid, [message_queue_len, stack_size]),
        {Pid, Messages, StackSize}
    end, Pids),
    SortedMembers = lists:keysort(2, lists:keysort(3, Members)),
    case SortedMembers of
        [{Pid, _Messages, _StackSize}] -> Pid;
        [{Pid, _Messages, _StackSize} | _Tail] -> Pid;
        _ -> {error, empty_process_group}
    end.
