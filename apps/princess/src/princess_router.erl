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
-export([route/2,register_route/1,unregister_route/1]).

-define(SERVER, ?MODULE).

-record(route, {id,pid}).

-record(state, {}).

%%%===================================================================
%%% API
%%%===================================================================

%Packet = Packet Data 
%ID = Client ID
route(ID,Packet) ->
    case catch do_route(ID,Packet) of
	{'EXIT', Reason} ->
		lager:log(error,?MODULE,"~p~nwhen processing: ~p",
		       [Reason, {ID, Packet}]);
	_ ->
	    ok
    end.

register_route(ID)->
	Pid = self(),
	F = fun () ->
		mnesia:write(#route{id = ID, pid = Pid })
		end,
	mnesia:transaction(F).

unregister_route(ID)->
	Pid = self(),
	F = fun () ->
		case mnesia:match_object(#route{id = ID,pid = Pid}) of
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
			[{ram_copies, [node()]},{type, bag},
			 {attributes, record_info(fields, route)}]),
    mnesia:add_table_copy(route, node(), ram_copies),
    mnesia:subscribe({table, route, simple}),
  	lists:foreach(fun (Pid) -> 
  			erlang:monitor(process, Pid)
		  end,
		  mnesia:dirty_select(route,
				      [{{route, '_', '$1'}, [], ['$1']}])),
	{ok, #state{}}.

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

handle_info({mnesia_table_event,{write, #route{id = _ID,pid = Pid}, _ActivityId}},
	    State) ->
	erlang:monitor(process, Pid),
    {noreply, State#state{}};

handle_info({'DOWN', _Ref, _Type, Pid, _Info}, State) ->

    F = fun () ->
		Es = mnesia:select(route,[{#route{_='_',pid = Pid},[],['$_']}]),
		lists:foreach(fun (E) ->
						mnesia:delete_object(E)
			      end,Es)
	end,
    mnesia:transaction(F),
    {noreply, State};
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
do_route(ID,Packet) ->
	case mnesia:dirty_read(route, ID) of
	   [] ->
	   		ok;
	   [R] ->
	   		Pid = R#route.pid,
	   		princess_handler:packet(Pid,Packet);
	   Rs ->
	   		Pids = lists:foldl(
	   			fun(E,Acc)->
	   				Pid = E#route.pid,
	   				[Pid|Acc]
	   			end,[],Rs),
	   		Pid = hm_process:least_busy_pid(Pids),
	   		princess_handler:packet(Pid,Packet)
    end.