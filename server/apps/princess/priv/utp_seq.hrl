%#define	SEQ_LT(a,b)	((int)((a)-(b)) < 0)
%#define	SEQ_LEQ(a,b)	((int)((a)-(b)) <= 0)
%#define	SEQ_GT(a,b)	((int)((a)-(b)) > 0)
%#define	SEQ_GEQ(a,b)	((int)((a)-(b)) >= 0)


-define(SEQ_MAX, 16#FFFFFFFF).
-define(SEQ_LT(A , B) , (((A - B) band ?SEQ_MAX) < 0)).
-define(SEQ_LEQ(A , B) , (((A - B) band ?SEQ_MAX) =< 0)).
-define(SEQ_GT(A , B) , (((A - B) band ?SEQ_MAX) > 0)).
-define(SEQ_GEQ(A , B) , (((A - B) band ?SEQ_MAX) >= 0)).
