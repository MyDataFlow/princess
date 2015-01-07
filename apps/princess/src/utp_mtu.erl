-module(utp_mtu).
-include ("utp.hrl").
-include ("utp_packet.hrl").
-export([new/0]).
-export([set_discover_time/2,set_floor/2,set_ceiling/2,set_last/2,
	set_probe_seq/2,set_probe_size/2]).
-export([get_discover_time/1,get_floor/1,get_ceiling/1,get_last/1,
	get_probe_seq/1,get_probe_size/1]).
-export([mtu_reset/1,mtu_search_update/1,packet_size/1]).


-record(utp_mtu_context,{
		mtu_discover_time = 0,
		mtu_floor = ?UTP_DEFAULT_MTU,
		mtu_ceiling = ?UDP_IPV4_MTU,
		mtu_last = ?UDP_IPV4_MTU,
		mtu_probe_seq = 0,
		mtu_probe_size = 0
	}).

new()->
	#utp_mtu_context{}.

set_discover_time(Context,DiscoverTime)->
	Context#utp_mtu_context{mtu_discover_time = DiscoverTime}.
set_floor(Context,MTUFloor)->
	Context#utp_mtu_context{mtu_floor = MTUFloor}.
set_ceiling(Context,MTUCeiling)->
	Context#utp_mtu_context{mtu_ceiling = MTUCeiling}.
set_last(Context,MTULast)->
	Context#utp_mtu_context{mtu_last = MTULast}.
set_probe_seq(Context,ProbSeq) ->
	Context#utp_mtu_context{mtu_probe_seq = ProbSeq}.
set_probe_size(Context,ProbSize)->
	Context#utp_mtu_context{mtu_probe_size = ProbSize}.

get_floor(Context)->
	Context#utp_mtu_context.mtu_floor.
get_ceiling(Context)->
	Context#utp_mtu_context.mtu_ceiling.
get_last(Context)->
	Context#utp_mtu_context.mtu_last.
get_probe_seq(Context)->
	Context#utp_mtu_context.mtu_probe_seq.
get_probe_size(Context)->
	Context#utp_mtu_context.mtu_probe_size.
get_discover_time(Context)->
	Context#utp_mtu_context.mtu_discover_time.


mtu_reset(Context)->
	Context#utp_mtu_context{
		mtu_discover_time = utp_time:current_time_milli() + ?UTP_DEFAULT_DISCOVER_TIME,
		mtu_ceiling = ?UDP_IPV4_MTU,
		mtu_floor = ?UTP_DEFAULT_MTU
	}.

mtu_search_update(Context)->
	MTUFloor = Context#utp_mtu_context.mtu_floor,
	MTUCeiling = Context#utp_mtu_context.mtu_ceiling,
	MTULast = (MTUFloor + MTUCeiling) / 2,
	if 
		MTUCeiling - MTUFloor =< 16 ->
			MTUDiscoverTime = utp_time:current_time_milli() + ?UTP_DEFAULT_DISCOVER_TIME,
			Context#utp_mtu_context{
				mtu_discover_time = MTUDiscoverTime,
				mtu_last = MTUFloor,
				mtu_ceiling = MTUFloor,
				mtu_probe_seq = 0,
				mtu_probe_size = 0
			};
		true ->
			Context#utp_mtu_context{
				mtu_last = MTULast,
				mtu_probe_seq = 0,
				mtu_probe_size = 0
			}
	end.

packet_size(Context)->
	MTU = if
		Context#utp_mtu_context.mtu_last > 0 ->
			Context#utp_mtu_context.mtu_last;
		true ->
			Context#utp_mtu_context.mtu_ceiling
		end,
	MTU - ?UTP_PACKET_HEADR_SIZE.
