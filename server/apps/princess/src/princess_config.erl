-module(princess_config).
-export([get/1]).

get(Key) ->
   case application:get_env(princess,Key) of
        undefined ->
            undefined;
        {ok,Val} ->
            Val
    end.
