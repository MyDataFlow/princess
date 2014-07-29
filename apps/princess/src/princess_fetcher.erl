%%%-------------------------------------------------------------------
%%% @author David Alpha Fox <>
%%% @copyright (C) 2014, David Alpha Fox
%%% @doc
%%%
%%% @end
%%% Created : 29 Jul 2014 by David Alpha Fox <>
%%%-------------------------------------------------------------------
-module(princess_fetcher).

-behaviour(gen_server).

%% API
-export([start_link/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
		 terminate/2, code_change/3]).
-export([fetch/4,to_free/3,client_close/2]).
-define(SERVER, ?MODULE).
-define(OPTIONS,
	[binary,
		{reuseaddr, true},
		{active, onec},
		{nodelay, true}
  ]).
-define(TIMEOUT,10000).
-record(state, {}).

%%%===================================================================
%%% API
%%%===================================================================
fetch(Pid,ID,Address,Port)->
	gen_server:call(?SERVER,{fetch,Pid,ID,Address,Port}).
to_free(Pid,ID,Bin)->
	gen_server:cast(?SERVER,{to_free,Pid,ID,Bin}).
client_close(Pid,ID)->
	gen_server:cast(?SERVER,{client_close,Pid,ID}).

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
	fetcher_monitor = ets:new(fetcher_monitor, [ordered_set, protected, named_table]),   
	fetcher_socket = ets:new(fetcher_socket, [ordered_set, protected, named_table]),   
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
handle_call({fetch,Pid,ID,Address,Port},_From,State)->
	hm_misc:monitor(Pid,fetcher_monitor),
	case ranch_tcp:connect(Address, Port, ?OPTIONS, ?TIMEOUT) of
  	{ok, TargetSocket} ->
    	ets:insert(fetcher_socket, {TargetSocket,Pid,ID}),
   		{reply,{ok,TargetSocket},State};
    {error, Error} ->
      {reply,{error,Error},State}
  end;

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
handle_cast({client_close,Pid,ID},State)->
	case ets:match_object(fetcher_socket,{'_',Pid,ID}) of
		[{Socket,Pid,ID}] ->
			ets:delete(fetcher_socket,Socket),
			ranch_tcp:close(Socket),
			{noreply, State};
    [] ->
	  	{noreply, State}
	end;
handle_cast({to_free,Pid,ID,Bin},State)->
	case ets:match_object(fetcher_socket,{'_',Pid,ID}) of
		[{Socket,Pid,ID}] ->
			ranch_tcp:send(Socket,Bin),
			{noreply, State};
    [] ->
	  	{noreply, State}
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
handle_info({tcp_closed, Socket},State) ->
	case ets:match_object(fetcher_socket,{Socket,'_','_'}) of
		[{Socket,Pid,ID}] ->
	  	magic_protocol:remote_close(Pid,ID),
			{noreply, State};
    [] ->
	  	{noreply, State}
	end;

handle_info({tcp, Socket, Bin},State)->
	case ets:match_object(fetcher_socket,{Socket,'_','_'}) of
		[{Socket,Pid,ID}] ->
	  	magic_protocol:to_fog(Pid,ID,Bin),
			{noreply, State};
    [] ->
	  	{noreply, State}
	end;
handle_info({'DOWN', _MonitorRef, process, Pid, _Info},State) -> 
	hm_misc:demonitor(Pid,fetcher_monitor),
	case ets:match_object(fetcher_socket,{'_',Pid,'_'}) of
		[] ->
			{noreply,State};
		Any ->
			loop_close(Any),
  		{noreply, State}
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
loop_close([])->
	ok;
loop_close([H|T])->
	{Socket,_Pid,_ID} = H,
	ets:delete(fetcher_socket,Socket),
	ranch_tcp:close(Socket),
	loop_close(T).