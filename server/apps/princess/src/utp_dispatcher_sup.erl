-module(utp_dispatcher_sup).
-behaviour(supervisor).

-export([start_link/3]).
-export([init/1]).

start_link(Port, DispatcherCount,Opts) ->
	supervisor:start_link(?MODULE, {
		Port, DispatcherCount, Opts
		}).

init({Port, DispatcherCount, Opts}) ->
	ChildSpecs = [
		{{utp_dispatcher, Port, N}, {utp_dispatcher, start_link, [
			Opts
		]}, permanent, brutal_kill, worker, [utp_dispatcher]}
			|| N <- lists:seq(1, DispatcherCount)],
	{ok, {{one_for_one, 10, 10}, ChildSpecs}}.
