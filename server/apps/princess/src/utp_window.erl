
-module(utp_window).

-include("utp.hrl").
-include("utp_packet.hrl").

-export([new/0]).
-export([update_window/8]).
-export([update_advertised_window/2,update_window_maxed_out/1]).
-export([update_max_window/2,update_cur_window/2]).
-export([get_max_window/1,get_cur_window/1]).
-export([max_snd_window/2,reply_micro/1,rto/1]).

-record(utp_window_context, {
          %% Size of the window the Peer advertises to us.
        peer_advertised_window = 255 * ?UTP_DEFAULT_PACKET_SIZE :: integer(),

          %% The current window size in the send direction, in bytes.
        cur_window = 0 :: integer(),
          %% Maximal window size int the send direction, in bytes.
          %% Also known as the current congestion window
        max_window = 255 * ?UTP_DEFAULT_PACKET_SIZE:: integer(),

          %% Current value to reply back to the other end
        reply_micro :: integer(),

          %% Round trip time measurements and LEDBAT
        min_rtt = 3000 :: integer(),
        round_trip  :: utp_rtt:t() | none,
        rtt_ledbat = none :: none | utp_ledbat:t(),
        our_ledbat = none :: none | utp_ledbat:t(),
        their_ledbat = none :: none | utp_ledbat:t(),
          %% Timeouts,
          %% --------------------
          %% Set when we update the zero window to 0 so we can reset it to 1.
        zero_window_timeout :: none | {set, reference()},

          %% Timestamps
          %% --------------------
          %% When was the window last totally full (in send direction)
        last_maxed_out_window = 0:: integer(),
        last_window_decay = 0 :: integer(),
        last_got_packet = 0 :: integer(),
        last_sent_packet = 0 :: integer()
       }).


%% ----------------------------------------------------------------------
new() ->
    Now = utp_time:current_time_milli(),
    #utp_window_context{ 
            last_maxed_out_window = Now ,
            last_window_decay     = Now - ?UTP_MAX_WINDOW_DECAY,
            last_got_packet = Now,
            last_sent_packet = Now 
        }.

update_cur_window(#utp_window_context{} = Wnd,C)->
  Wnd#utp_window_context{cur_window = C}.
get_cur_window(#utp_window_context{} = Wnd)->
  Wnd#utp_window_context.cur_window.
update_max_window(#utp_window_context{} = Wnd,Max)->
  Wnd#utp_window_context{max_window = Max}.
get_max_window(#utp_window_context{} = Wnd)->
  Wnd#utp_window_context.max_window.

max_snd_window(#utp_window_context{peer_advertised_window = AdvertisedWindow,
    max_window = MaxSendWindow },PacketSize) ->
    Min = lists:min([PacketSize, AdvertisedWindow, MaxSendWindow]),
    Min.

reply_micro(#utp_window_context{reply_micro = ReplyMicro})->
    ReplyMicro.

rto(#utp_window_context { round_trip = RTT }) ->
    utp_rtt:rto(RTT).

ack_rtt(#utp_window_context{round_trip = RTT,
    min_rtt    = MinRTT,rtt_ledbat = LedbatHistory } = Wnd,TimeSent, TimeAcked) ->
    {ok, _NewRTO, NewRTT, NewHistory} = utp_rtt:ack_rtt(LedbatHistory,
                                                           RTT,
                                                           TimeSent,
                                                           TimeAcked),
    Wnd#utp_window_context { round_trip = NewRTT,
                 min_rtt = min(TimeAcked - TimeSent, MinRTT),
                 rtt_ledbat     = NewHistory}.

congestion_control(#utp_window_context {} = Wnd, 0,_PacketSize) ->
    Wnd; %% Nothing acked, so skip maintaining the congestion control
congestion_control(#utp_window_context { max_window = MaxWindow,
    our_ledbat = OurHistory,min_rtt = MinRTT,
    last_maxed_out_window = LastMaxedOutTime } = Wnd,BytesAcked,PacketSize) when BytesAcked > 0 ->
    case MinRTT of
        K when K > 0 ->
            ignore;
        K ->
            error({min_rtt_violated, K})
    end,
    OurDelay =
        case min(MinRTT, utp_ledbat:get_value(OurHistory)) of
            O when O >= 0 ->
                O;
            Otherwise ->
                error({our_delay_violated, Otherwise})
        end,
    utp_trace:trace(queue_delay, OurDelay),
    TargetDelay = ?UTP_CCONTROL_TARGET,

    TargetOffset = TargetDelay - OurDelay,
    utp_trace:trace(target_offset, TargetOffset),
    %% Compute the Window Factor. The window might have shrunk since
    %% last time, so take the minimum of the bytes acked and the
    %% window maximum.  Divide by the maximal value of the Windows and
    %% the bytes acked. This will yield a ratio which tells us how
    %% full the window is. If the window is 30K and we just acked 10K,
    %% then this value will be 10/30 = 1/3 meaning we have just acked
    %% 1/3 of the window. If the window has shrunk, the same holds,
    %% but opposite. We must make sure that only the size of the
    %% window is considered, so we track the minimum. that is, if the
    %% window has shrunk from 30 to 10, we only allow an update of the
    %% size 1/3 because this is the factor we can safely consider.
    WindowFactor = min(BytesAcked, MaxWindow) / max(MaxWindow, BytesAcked),

    %% The delay factor is how much we are off the target:
    DelayFactor = TargetOffset / TargetDelay,
    
    %% How much is the scaled gain?
    ScaledGain = ?UTP_MAX_WND_INCREASE_BYTES_PER_RTT * WindowFactor * DelayFactor,
    
    case ScaledGain =< 1 + ?UTP_MAX_WND_INCREASE_BYTES_PER_RTT * WindowFactor of
        true -> ignore;
        false ->
            error({scale_gain_violation, ScaledGain, BytesAcked, MaxWindow})
    end,

    Alteration = case consider_last_maxed_window(LastMaxedOutTime) of
                     too_soon ->
                         0;
                     ok ->
                         ScaledGain
                 end,
    NewMaxWindow = utp_util:clamp(MaxWindow + Alteration, ?UTP_MIN_WINDOW_SIZE,PacketSize),
    utp_trace:trace(congestion_window, NewMaxWindow),
    Wnd#utp_window_context {
      max_window = round(NewMaxWindow)
     }.

consider_last_maxed_window(LastMaxedOutTime) ->    
    Now = utp_time:current_time_milli(),
    case Now - LastMaxedOutTime > 300 of
        true ->
            too_soon;
        false ->
            ok
    end.
update_window_maxed_out(#utp_window_context {} = Wnd) ->
    Wnd#utp_window_context {
      last_maxed_out_window = utp_time:current_time_milli()
     }.

update_clock_skew(#utp_window_context{ their_ledbat = none }, NW) ->
    NW;
update_clock_skew(#utp_window_context {
                     their_ledbat = OldTheirs },
                  #utp_window_context {
                    their_ledbat = Theirs,
                    our_ledbat   = Ours
                   } = NW) ->
    OldDelayBase = utp_ledbat:base_delay(OldTheirs),
    TheirBase = utp_ledbat:base_delay(Theirs),
    Diff = OldDelayBase - TheirBase,
    case utp_ledbat:compare_less(
           TheirBase,
           OldDelayBase) of
        true when Diff < 10000 ->
            NW#utp_window_context{ our_ledbat = utp_ledbat:shift(Ours, Diff) };
        true ->
            NW;
        false ->
            NW
    end.


update_advertised_window(#utp_window_context{} = Wnd, NewWin)->
    Wnd#utp_window_context { peer_advertised_window = NewWin }.

update_reply_micro(#utp_window_context{ their_ledbat = TL } = Wnd, RU) ->
    Wnd#utp_window_context { reply_micro = RU,
        their_ledbat = utp_ledbat:add_sample(TL,RU) }.
update_rtt_ledbat(#utp_window_context { rtt_ledbat = Ledbat } = Wnd, Sample) ->
    Wnd#utp_window_context { rtt_ledbat = utp_ledbat:add_sample(Ledbat, Sample) }.
update_our_ledbat(#utp_window_context { our_ledbat = Ledbat } = Wnd, Sample) ->
    Wnd#utp_window_context { our_ledbat = utp_ledbat:add_sample(Ledbat, Sample) }.

update_estimate_exceed(#utp_window_context { min_rtt = MinRTT,
                                  our_ledbat = Ours
                                } = NW) ->
    OurDelay = utp_ledbat:get_value(Ours),
    Diff = OurDelay - MinRTT,
    case Diff of
        K when K > 0 ->
            NW#utp_window_context {
              our_ledbat = utp_ledbat:shift(Ours, K) };
        _Otherwise ->
            NW
    end.
update_window(Wnd, ReplyMicro, TimeAcked,SentTimes,BytesAcked,TSDiff,
     AdvertisedWindow,PacketSize) ->
    N6 = update_reply_micro(Wnd, ReplyMicro),
    N5 = update_clock_skew(Wnd,N6),
    N4 = update_our_ledbat(N5, TSDiff),
    N3 = update_estimate_exceed(N4),
    N2 = update_advertised_window(N3, AdvertisedWindow),
    N = lists:foldl(fun(TimeSent, Acc) ->
            ack_rtt(Acc,TimeSent,TimeAcked)
        end,N2,SentTimes),
    congestion_control(N, BytesAcked,PacketSize).
