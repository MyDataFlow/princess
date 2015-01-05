-module(hm_misc).
-export([monitor/2,demonitor/2]).
-export([monitor_dict/2,demonitor_dict/2]).

monitor(Pid,Tab) ->
	case ets:match_object(Tab, {Pid,'_'}) of
  	[] ->
    	M = erlang:monitor(process, Pid),
      ets:insert(Tab, {Pid, M});
    _ ->
    	ok
  end.

demonitor(Pid,Tab) ->
  case ets:match_object(Tab,{Pid,'_'}) of
  	[{Pid,Ref}] ->
	  	erlang:demonitor(Ref),
      ets:delete(Tab,Pid),
			ok;
    [] ->
	    ok
  end.

monitor_dict(Pid,Dict)->
  R = dict:find(Pid,Dict),
  case R of 
    {ok,_Ref}->
      Dict;
    _->
      M = erlang:monitor(process, Pid),
      dict:store(Pid,M,Dict)
  end.
demonitor_dict(Pid,Dict)->
  R = dict:find(Pid,Dict),
  case R of
      {ok,Ref}->
        erlang:demonitor(Ref),
        dict:erase(Pid,Ref);
      _->
        Dict
  end.
