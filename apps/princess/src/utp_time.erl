-module(utp_time).
-export([current_time_micro/0,current_time_milli/0]).

current_time_micro() ->
    {M, S, Micro} = os:timestamp(),
    S1 = M*1000000 + S,
    Micro + S1*1000000.

current_time_milli() ->
    {M, S, Micro} = os:timestamp(),
    (Micro div 1000) + S*1000 + M*1000000*1000.