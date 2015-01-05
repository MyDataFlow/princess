%%%-------------------------------------------------------------------
%%% @author davidalphafox <>
%%% @copyright (C) 2015, davidalphafox
%%% @doc
%%%
%%% @end
%%% Created :  5 Jan 2015 by davidalphafox <>
%%%-------------------------------------------------------------------
-module(princess_router).

-behaviour(gen_server).

%% API
-export([start_link/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
		 terminate/2, code_change/3]).
-export([route_to_acceptor/2,route_to_worker/2,register_route/3,unregister_route/1]).

-define(SERVER, ?MODULE).

-record(route, {id,acceptor,worker}).

-record(state, {monitors}).

%%%===================================================================
%%% API
%%%===================================================================
route_to_acceptor(ID,Packet) ->
    case catch do_route(ID,Packet,acceptor) of
	{'EXIT', Reason} ->
		lager:log(error,?MODULE,"~p~nwhen processing: ~p",
		       [Reason, {ID, Packet}]);
	_ ->
	    ok
    end.
route_to_worker(ID,Packet) ->
    case catch do_route(ID,Packet,worker) of
	{'EXIT', Reason} ->
		lager:log(error,?MODULE,"~p~nwhen processing: ~p",
		       [Reason, {ID, Packet}]);
	_ ->
	    ok
    end.
register_route(ID,Acceptor,Worker)->
	F = fun () ->
		mnesia:write(#route{id = ID, acceptor = Acceptor,
						worker = Worker})
		end,
	mnesia:transaction(F).
unregister_route(ID)->
	F = fun () ->
		case mnesia:match_object(#route{id = ID,_ = '_', _ = '_'}) of
			[R] -> 
				mnesia:delete_object(R);
			_ -> ok
		end
	end,
	mnesia:transaction(F).
%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link() ->
	gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init([]) ->
    mnesia:create_table(route,
			[{ram_copies, [node()]},
			 {attributes, record_info(fields, route)}]),
    mnesia:add_table_copy(route, node(), ram_copies),
    mnesia:subscribe({table, route, simple}),
    lists:foreach(fun (R) -> 
    		erlang:monitor(process, R#route.acceptor),
    		erlang:monitor(process, R#route.worker)
		  end,
		  mnesia:dirty_select(route,
				      [{{route, '_', '_', '_'}, [], ['$_']}])),
    Monitors = dict:new(),
	{ok, #state{monitors = Monitors}}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call(_Request, _From, State) ->
	Reply = ok,
	{reply, Reply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->
	{noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------

handle_info({mnesia_table_event,{write, #route{id = ID,acceptor = Acceptor,worker = Worker}, _ActivityId}},
	    State) ->
    M = State#state.monitors,
    M1 = hm_misc:monitor_dict(Acceptor,M),
    M2 = hm_misc:monitor_dict(Worker,M1),
    {noreply, State#state{monitors = M2}};

handle_info({'DOWN', _Ref, _Type, Pid, _Info}, State) ->
	M = State#state.monitors,
	M1 = hm_misc:demonitor_dict(Pid),
    F = fun () ->
		Es = mnesia:select(route,
				   [{#route{acceptor = Pid, _ = '_'}, [], ['$_']}]),
		lists:foreach(fun (E) ->
						ID = E#route.id,
						Worker = E#route.worker,
						princess_worker:acceptor_down(Worker,ID),
						mnesia:delete_object(E)
			      end,Es),
		Es2 = mnesia:select(route,[{#route{_='_',worker = Pid},[],['$_']}]),
		lists:foreach(fun (E2) ->
						ID = E2#route.id,
						Acceptor = E2#route.acceptor,
						princess_acceptor:worker_down(Acceptor,ID),
						mnesia:delete_object(E2)
			      end,Es2)
	end,
    mnesia:transaction(F),
    {noreply, State#state{monitors = M1}};
handle_info(_Info, State) ->
	{noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
	ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
do_route(ID,Packet,Direct) ->
	case {mnesia:dirty_read(route, ID),Direct} of
	    {[],_} -> 
	    	ok;
	    {[R],acceptor} ->
	    	Acceptor = R#route.acceptor,
	    	princess_acceptor:packet(Acceptor,{ID,Packet});
	    {[R],worker} ->
	    	Worker = R#route.worker,
	    	princess_worker:packet(Worker,{ID,Packet})
    end.