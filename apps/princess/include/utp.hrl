-define(UTP_STATE_CS_UNINITIALIZED,state_uninitialized).
-define(UTP_STATE_CS_IDLE,state_idle).
-define(UTP_STATE_CS_SYN_SENT,state_syn_sent).
-define(UTP_STATE_CS_CONNECTED,state_connected).
-define(UTP_STATE_CS_CONNECTED_FULL,state_connected_full).
-define(UTP_STATE_CS_GOT_FIN,state_fot_fin).
-define(UTP_STATE_CS_DESTROY_DELAY,state_destroy_delay).
-define(UTP_STATE_CS_FIN_SENT,state_fin_sent).
-define(UTP_STATE_CS_RESET,state_rest).
-define(UTP_STATE_CS_DESTROY,state_dstory).

-define(UTP_DEFAULT_RTO,3000).
-define(UTP_DEFAULT_RTT,800).
-define(UTP_DEFAULT_PACKET_SIZE,1435).
-define(UTP_DEFAULT_DISCOVER_TIME,30 * 60 * 1000).
-define(UTP_DEFAULT_MTU,576).

%NAT 29 seconds
-define(UTP_KEEPALIVE_INTERVAL,29000).

-define(UTP_SEQ_NR_MASK,16#FFFF).
-define(UTP_ACK_NR_MASK,16#FFFF).
-define(UTP_TIMESTAMP_MASK,16#FFFFFFFF).

-define(ETHERNET_MTU,1500).
-define(IPV4_HEADER_SIZE,20).
-define(IPV6_HEADER_SIZE,40).
-define(UDP_HEADER_SIZE,8).
-define(GRE_HEADER_SIZE,24).
-define(PPPOE_HEADER_SIZE,8).
-define(MPPE_HEADER_SIZE,2).
-define(FUDGE_HEADER_SIZE,36).
-define(TEREDO_MTU,1280).

-define(UDP_IPV4_MTU,(?ETHERNET_MTU - ?IPV4_HEADER_SIZE - ?UDP_HEADER_SIZE 
	- ?GRE_HEADER_SIZE - ?PPPOE_HEADER_SIZE - ?MPPE_HEADER_SIZE 
	- ?FUDGE_HEADER_SIZE)).
