-module(utp_util).
-include("utp_packet.hrl").

-export([
         bit16/1,
         bit32/1
         ]).

-export([canonicalize_address/1]).
-export([lookup_connection/2,add_connection/2,del_connection/2]).
-export([send/4,send_aux/5,send_reset/5]).
-export([clamp/3]).
-export([random_id/0]).

%% @doc `bit16(Expr)' performs `Expr' modulo 65536
%% @end
-spec bit16(integer()) -> integer().
bit16(N) when is_integer(N) ->
    N band 16#FFFF.

-spec bit32(integer()) -> integer().
bit32(N) when is_integer(N) ->
    N band 16#FFFFFFFF.


%% ---------------------------------------------------------------------

canonicalize_address(S) when is_list(S) ->
    {ok, CAddr} = inet:getaddr(S, inet),
    CAddr;
canonicalize_address({_, _, _, _} = Addr) ->
    Addr.
%% ----------------------------------------------------------------------
clamp(Val, Min, _Max) when Val < Min -> Min;
clamp(Val, _Min, Max) when Val > Max -> Max;
clamp(Val, _Min, _Max) -> Val.
%% ----------------------------------------------------------------------
lookup_connection(Key,Tid)->
	case ets:match_object(Tid,Key) of 
		[] ->
			undefined;
		[{Key,UTPSocket}] ->
			UTPSocket
	end.

add_connection({Key,Value},Tid)->
	ets:insert(Tid,{Key,Value}).

del_connection(Key,Tid)->
    ets:delete(Tid,Key).
%% ----------------------------------------------------------------------
send_reset(Socket, Host, Port, ConnectionID, AckNo) ->
    Header = #packet_ver_one_header{ 
        type = ?UTP_PACKET_ST_RESET,
        version = 1,
        extension = 0,
        connection_id = ConnectionID,
        timestamp_ms = 0,
        timestamp_df_ms = 0,
        wnd_size = 0,
        seq_nr = utp_protocol:random_id(),
        ack_nr = AckNo},
    {ok,Payload} = utp_protocol:encode(Header,[],<<>>),
    send(Socket, Host, Port, Payload).

send(Socket,Host,Port,Payload)->
    send_aux(1,Socket,Host,Port,Payload).

send_aux(0, Socket, Host, Port, Payload) ->
   case  gen_udp:send(Socket, Host, Port, Payload) of
        ok ->
            {ok,utp_time:current_time_milli()};
        {error,Reason}->
            {error, Reason}
    end;
send_aux(N, Socket, Host, Port, Payload) ->
    case gen_udp:send(Socket, Host, Port, Payload) of
        ok ->
            {ok, utp_time:current_time_milli()};
        {error, enobufs} ->
            %% Special case this
            timer:sleep(150), % Wait a bit for the queue to clear
            send_aux(N-1, Socket, Host, Port, Payload);
        {error, Reason} ->
            {error, Reason}
    end.
%% ----------------------------------------------------------------------
random_id() ->
    <<N:16/integer>> = crypto:rand_bytes(2),
    N.