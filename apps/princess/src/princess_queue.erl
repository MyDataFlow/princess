%%%-------------------------------------------------------------------
%%% @author David Alpha Fox <>
%%% @copyright (C) 2014, David Alpha Fox
%%% @doc
%%%
%%% @end
%%% Created : 30 Jul 2014 by David Alpha Fox <>
%%%-------------------------------------------------------------------
-module(princess_queue).

-behaviour(gen_server).

%% API
-export([start_link/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
		 terminate/2, code_change/3]).

-export([client_open/3,client_close/1]).
-export([remote_open/2,remote_close/2]).
-export([transfer_to_channel/3,transfer_to_fetcher/3]).

-define(SERVER, ?MODULE).

-record(state, {
		workers,
		waiting,
		monitors
	}).

%%%===================================================================
%%% API
%%%===================================================================
transfer_to_channel(Channel,ID,Bin)->
  Fetcher = self(),
	gen_server:cast(Channel,{transfer_to_channel,Fetcher,ID,Bin}).
transfer_to_fetcher(Fetcher,ID,Bin)->
  Channel = self(),
	gen_server:cast(Fetcher,{transfer_to_fetcher,Channel,ID,Bin}).
client_open(ID,Address,Port)->
	Channel = self(),
	gen_server:cast(?SERVER,{client_open,Channel,ID,Address,Port}).
client_close(ID)->
	Channel = self(),
	gen_server:cast(?SERVER,{client_close,Channel,ID}).
remote_open(Channel,ID)->
	Fetcher = self(),
	gen_server:cast(?SERVER,{remote_open,Channel,Fetcher,ID}).
remote_close(Channel,ID)->
	Fetcher = self(),
	gen_server:cast(?SERVER,{remote_close,Channel,Fetcher,ID}).
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
	Workers = queue:new(),
  Waiting = queue:new(),
  Monitors = ets:new(monitors, [private]),
  State = #state{
  	workers = Workers,
  	waiting = Waiting,
  	monitors = Monitors
  },
	{ok, State}.

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
handle_cast({client_open,Channel,ID,Address,Port},State)->
	#state{
		workers = Workers,
		monitors = Monitors
	} = State,
	case queue:out(Workers) of
		{{value, Fetcher}, Left} ->
			Ref = erlang:monitor(process, Channel),
			true = ets:insert(Monitors, {Ref,Channel,ID,Fetcher}),
			princess_fetcher:client_open(Fetcher,Channel,ID,Address,Port),
			{noreply,State#state{workers = Left}};
		{empty, Empty} ->
			Ref = erlang:monitor(process,Channel),
			Waiting = queue:in({Channel,Ref,{ID,Address,Port}},State#state.waiting),
			{noreply, State#state{workers = Empty,waiting = Waiting}}
	end;

handle_cast({client_close,Channel,ID},State)->
	#state{
		monitors = Monitors
	} = State,
	case ets:match_object(Monitors,{'_',Channel,ID,'_'}) of
		[{Ref,Channel,ID,Fetcher}] ->
    	true = ets:delete(Monitors, Ref),
    	erlang:demonitor(Ref),
    	princess_fetcher:client_close(Fetcher,Channel,ID),
    	handle_checkin(Fetcher,State);
    []->
    	Fun = fun ({{C, R},{I,_,_}})->
    			case C =/= Channel of
    				true ->
    					true;
    				false ->
    					case I =/= ID of
    						true ->
    							true;
    						false ->
    							erlang:demonitor(R),
    							false
    					end
    			end
    		end,
    	Waiting = queue:filter(Fun,State#state.waiting),
    	{noreply, State#state{waiting = Waiting}}
    end;
handle_cast({remote_open,Channel,Fetcher,ID},State)->
	magic_protocol:remote_open(Channel,Fetcher,ID),
	handle_checkin(Fetcher,State);
handle_cast({remote_close,Channel,Fetcher,ID},State)->
	#state{
		monitors = Monitors
	} = State,
	case ets:match_object(Monitors,{'_',Channel,ID,'_'}) of
		[{Ref,Channel,ID,Fetcher}] ->
    	true = ets:delete(Monitors, Ref),
    	erlang:demonitor(Ref),
    	magic_protocol:remote_close(Channel,Fetcher,ID),
    	handle_checkin(Fetcher,State);
    [] ->
    	magic_protocol:remote_close(Channel,Fetcher,ID),
    	State
  end;
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

handle_info({'DOWN', Ref, _, _, _}, State) ->
	case ets:match_object(State#state.monitors, {Ref, '_','_','_'}) of
  	[{_,Channel,_ID,Fetcher}] ->
    	true = ets:delete(State#state.monitors, Ref),
    	princess_fetcher:channel_close(Fetcher,Channel),
      {noreply,State};
    [] ->
    	Waiting = queue:filter(fun ({{_, R},_}) -> R =/= Ref end, State#state.waiting),
      {noreply, State#state{waiting = Waiting}}
  end;
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
handle_checkin(Fetcher, State) ->
	#state{
  	waiting = Waiting,
    monitors = Monitors
  } = State,
  
  case queue:out(Waiting) of
  	{{value, {{Channel,Ref}, {ID,Address,Port}}}, Left} ->
      true = ets:insert(Monitors, {Ref,Channel,ID,Fetcher}),
      princess_fetcher:client_open(Fetcher,Channel,ID,Address,Port),
      State#state{waiting = Left};
    {empty, Empty} ->
    	case queue:member(Fetcher,State#state.workers) of
    		true ->
    			State;
    		false->
      		Workers = queue:in(Fetcher,State#state.workers),
      		State#state{workers = Workers, waiting = Empty}
      end
  end.