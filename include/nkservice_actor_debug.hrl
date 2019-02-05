-ifndef(NKSERVICE_ACTOR_DEBUG_HRL_).
-define(NKSERVICE_ACTOR_DEBUG_HRL_, 1).

%% ===================================================================
%% Defines
%% ===================================================================

-include("nkservice_actor.hrl").

-define(ACTOR_DEBUG(Txt, Args),
    case erlang:get(nkservice_actor_debug) of
        true -> ?ACTOR_LOG(debug, Txt, Args);
        _ -> ok
    end).


-define(ACTOR_DEBUG(Txt, Args, State),
    case erlang:get(nkservice_actor_debug) of
        true -> ?ACTOR_LOG(debug, Txt, Args, State);
        _ -> ok
    end).


-define(ACTOR_LOG(Type, Txt, Args),
    lager:Type("NkSERVICE Actor " ++ Txt, Args)).


-define(ACTOR_LOG(Type, Txt, Args, State),
    lager:Type(
        [
            {srv_id, State#actor_st.actor#actor.id#actor_id.domain},
            {uid, State#actor_st.actor#actor.id#actor_id.uid},
            {class, State#actor_st.actor#actor.id#actor_id.group}
        ],
        "NkSERVICE ~s Actor ~s (~s, ~s) " ++ Txt,
        [
            State#actor_st.actor#actor.id#actor_id.domain,
            State#actor_st.actor#actor.id#actor_id.name,
            State#actor_st.actor#actor.id#actor_id.group,
            State#actor_st.actor#actor.id#actor_id.uid | Args
        ]
    )).

-endif.