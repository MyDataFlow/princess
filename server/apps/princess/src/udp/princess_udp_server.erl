-module(princess_udp_server).

-behaviour(gen_server2).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
        terminate/2, code_change/3]).

-record(state, {
    socket,
    port,
    timeout
}).

-define(DEFAULT_TIMEOUT, 3000).
-define(DEFAULT_UDP_PORT, 9092).
-define(UDP_SOCKET_OPTIONS, [binary,{active, once}, {reuseaddr, true}]).

%%====================================================================
%% API
%%====================================================================
start_link(Port, Timeout) ->
    gen_server2:start_link({local, ?MODULE}, ?MODULE, [Port, Timeout], 
        [{timeout, Timeout}]).


%%====================================================================
%% gen_server callbacks
%%====================================================================

init([Port, Timeout]) ->
    case catch gen_udp:open(Port, ?UDP_SOCKET_OPTIONS) of
        {ok, Socket} ->
            State = #state{
                socket  = Socket,
                port    = Port,
                timeout = Timeout
            },
            {ok, State};
        {error, Reason} ->
            {stop, {error, Reason}}
    end.

handle_call(_, _From, State) ->
    {noreply, State}.


handle_cast(_, State) ->
    {noreply, State}.


handle_info({udp, _, _, _, Packet}, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    ok.

code_change(_, _, State) ->
    {ok, State}.
