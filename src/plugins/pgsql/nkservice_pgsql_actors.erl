%% -------------------------------------------------------------------
%%
%% Copyright (c) 2018 Carlos Gonzalez Florido.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

-module(nkservice_pgsql_actors).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-export([init/2, drop/2]).
-export([find/3, read/3, save/4, delete/4,search/4, aggregation/4]).
-export([get_links/4, get_linked/4]).
-export([get_service/3, update_service/4]).
-export([query/3, query/4]).
-export_type([result_fun/0]).

-include("nkservice.hrl").
-include("nkservice_actor.hrl").


-define(LLOG(Type, Txt, Args), lager:Type("NkSERVICE PGSQL Actors "++Txt, Args)).
-define(RETURN_NOTHING,  <<" RETURNING NOTHING; ">>).


%% ===================================================================
%% Types
%% ===================================================================

-type result_fun() :: fun(([[tuple()]], map()) -> {ok, term(), map()} | {error, term()}).



%% ===================================================================
%% API
%% ===================================================================

%% @private
init(SrvId, PackageId) ->
    init(SrvId, PackageId, 10).


%% @private
init(SrvId, PackageId, Tries) when Tries > 0 ->
    case query(SrvId, PackageId, <<"SELECT id,version FROM versions">>) of
        {ok, [Rows], _} ->
            case maps:from_list(Rows) of
                #{
                    <<"actors">> := ActorsVsn,
                    <<"links">> := LinksVsn,
                    <<"fts">> := FtsVsn
                } ->
                    case {ActorsVsn, LinksVsn, FtsVsn} of
                        {<<"1">>, <<"1">>, <<"1">>} ->
                            ?LLOG(notice, "detected database at last version", []),
                            ok;
                        _ ->
                            ?LLOG(warning, "detected database at wrong version", []),
                            ok
                    end;
                _ ->
                    ?LLOG(error, "unrecognized database!", []),
                    {error, database_unrecognized}
            end;
        {error, relation_unknown} ->
            ?LLOG(warning, "database not found: Creating it", []),
            case query(SrvId, PackageId, create_database_query()) of
                {ok, _, _} ->
                    ok;
                {error, Error} ->
                    ?LLOG(warning, "Could not create database: ~p", [Error]),
                    {error, Error}
            end;
        {error, Error} ->
            ?LLOG(notice, "could not create database: ~p (~p tries left)", [Error, Tries]),
            timer:sleep(1000),
            init(SrvId, PackageId, Tries-1)
    end;

init(_SrvId, _PackageId, _Tries) ->
    {error, database_not_available}.



%% @private
drop(SrvId, PackageId) ->
    Q = <<"
        DROP TABLE IF EXISTS versions CASCADE;
        DROP TABLE IF EXISTS actors CASCADE;
        DROP TABLE IF EXISTS links CASCADE;
        DROP TABLE IF EXISTS fts CASCADE;
        DROP TABLE IF EXISTS domains CASCADE;
    ">>,
    case query(SrvId, PackageId, Q) of
        {ok, _, _} ->
            ok;
        {error, Error} ->
            {error, Error}
    end.


%% @private
create_database_query() ->
    <<"
        BEGIN;
        CREATE TABLE versions (
            id STRING PRIMARY KEY NOT NULL,
            version STRING NOT NULL
        );
        CREATE TABLE actors (
            uid STRING PRIMARY KEY NOT NULL,
            srv STRING NOT NULL,
            class STRING NOT NULL,
            actor_type STRING NOT NULL,
            name STRING NOT NULL,
            vsn STRING NOT NULL,
            data JSONB NOT NULL,
            metadata JSONB NOT NULL,
            path STRING NOT NULL,
            last_update STRING NOT NULL,
            expires STRING,
            fts_words STRING,
            UNIQUE INDEX name_idx (srv, class, actor_type, name),
            INDEX path_idx (path, class),
            INDEX last_update_idx (last_update),
            INDEX expires_idx (expires),
            INVERTED INDEX data_idx (data),
            INVERTED INDEX metadata_idx (metadata)
        );
        INSERT INTO versions VALUES ('actors', '1');
        CREATE TABLE labels (
            uid STRING NOT NULL REFERENCES actors(uid) ON DELETE CASCADE,
            label_key STRING NOT NULL,
            label_value STRING NOT NULL,
            path STRING NOT NULL,
            PRIMARY KEY (uid, label_key),
            UNIQUE INDEX label_idx (label_key, uid)
        ) INTERLEAVE IN PARENT actors(uid);
        INSERT INTO versions VALUES ('labels', '1');
        CREATE TABLE links (
            uid STRING NOT NULL REFERENCES actors(uid) ON DELETE CASCADE,
            link_type STRING NOT NULL,
            link_target STRING NOT NULL REFERENCES actors(uid) ON DELETE CASCADE,
            path STRING NOT NULL,
            PRIMARY KEY (uid, link_target, link_type),
            UNIQUE INDEX link_idx (link_target, link_type, uid)
        ) INTERLEAVE IN PARENT actors(uid);
        INSERT INTO versions VALUES ('links', '1');
        CREATE TABLE fts (
            uid STRING NOT NULL REFERENCES actors(uid) ON DELETE CASCADE,
            fts_word STRING NOT NULL,
            fts_field STRING NOT NULL,
            path STRING NOT NULL,
            PRIMARY KEY (uid, fts_word, fts_field),
            UNIQUE INDEX fts_idx (fts_word, fts_field, uid)
        )  INTERLEAVE IN PARENT actors(uid);
        INSERT INTO versions VALUES ('fts', '1');
        CREATE TABLE services (
            srv STRING PRIMARY KEY NOT NULL,
            cluster STRING NOT NULL,
            node STRING NOT NULL,
            last_update STRING NOT NULL,
            pid STRING NOT NULL
        );
        INSERT INTO versions VALUES ('services', '1');
        COMMIT;
    ">>.


%% @doc Called from actor_db_find callback
find(SrvId, PackageId, #actor_id{}=ActorId) ->
    #actor_id{srv=ActorSrvId, class=Class, type=Type, name=Name} = ActorId,
    Query = [
        <<"SELECT uid FROM actors">>,
        <<" WHERE srv=">>, quote(ActorSrvId),
        <<" AND class=">>, quote(Class),
        <<" AND actor_type=">>, quote(Type),
        <<" AND name=">>, quote(Name), <<";">>
    ],
    case query(SrvId, PackageId, Query) of
        {ok, [[{UID}]], QueryMeta} ->
            {ok, ActorId#actor_id{uid=UID, pid=undefined}, QueryMeta};
        {ok, [[]], _} ->
            {error, actor_not_found};
        {error, Error} ->
            {error, Error}
    end;

find(SrvId, PackageId, UID) ->
    Query = [
        <<"SELECT srv,class,actor_type,name FROM actors">>,
        <<" WHERE uid=">>, quote(UID), <<";">>
    ],
    case query(SrvId, PackageId, Query) of
        {ok, [[{ActorSrvId, Class, Type, Name}]], QueryMeta} ->
            ActorId = #actor_id{
                srv = get_srv(ActorSrvId),
                uid = UID,
                class = Class,
                type = Type,
                name = Name,
                pid = undefined
            },
            {ok, ActorId, QueryMeta};
        {ok, [[]], _} ->
            {error, actor_not_found};
        {error, Error} ->
            {error, Error}
    end.


%% @doc Called from actor_db_read callback
read(SrvId, PackageId, #actor_id{}=ActorId) ->
    #actor_id{srv=ActorSrvId, class=Class, type=Type, name=Name} = ActorId,
    Query = [
        <<"SELECT uid,vsn,metadata,data FROM actors ">>,
        <<" WHERE srv=">>, quote(ActorSrvId),
        <<" AND class=">>, quote(Class),
        <<" AND actor_type=">>, quote(Type),
        <<" AND name=">>, quote(Name), <<";">>
    ],
    case query(SrvId, PackageId, Query) of
        {ok, [[Fields]], QueryMeta} ->
            {UID, Vsn, {jsonb, Meta}, {jsonb, Data}} = Fields,
            Actor = #actor{
                id = #actor_id{
                    uid = UID,
                    srv = ActorSrvId,
                    class = Class,
                    type = Type,
                    name = Name
                },
                vsn = Vsn,
                data = nklib_json:decode(Data),
                metadata = nklib_json:decode(Meta)
            },
            {ok, Actor, QueryMeta};
        {ok, [[]], _QueryMeta} ->
            {error, actor_not_found};
        {error, Error} ->
            {error, Error}
    end;

read(SrvId, PackageId, UID) ->
    UID2 = to_bin(UID),
    Query = [
        <<"SELECT srv,class,actor_type,name,vsn,metadata,data FROM actors ">>,
        <<" WHERE uid=">>, quote(UID2), <<";">>
    ],
    case query(SrvId, PackageId, Query) of
        {ok, [[Fields]], QueryMeta} ->
            {ActorSrvId, Class, Type, Name, Vsn, {jsonb, Meta}, {jsonb, Data}} = Fields,
            Actor = #actor{
                id = #actor_id{
                    uid = UID2,
                    srv = get_srv(ActorSrvId),
                    class = Class,
                    type = Type,
                    name = Name
                },
                vsn = Vsn,
                data = nklib_json:decode(Data),
                metadata = nklib_json:decode(Meta)
            },
            {ok, Actor, QueryMeta};
        {ok, [[]], _QueryMeta} ->
            {error, actor_not_found};
        {error, Error} ->
            {error, Error}
    end.



-record(save_fields, {
    uids = [],
    actors = [],
    labels = [],
    links = [],
    fts = []
}).


%% @doc Called from actor_srv_save callback
%% Links to invalid objects will not be allowed (foreign key)
save(SrvId, PackageId, Mode, #actor{}=Actor) ->
    save(SrvId, PackageId, Mode, [Actor]);

save(SrvId, PackageId, Mode, Actors) ->
    Fields = populate_fields(Actors, #save_fields{}),
    #save_fields{
        uids = UIDs,
        actors = ActorFields,
        labels = LabelFields,
        links = LinkFields,
        fts = FtsFields
    } = Fields,
    Verb = case Mode of
        create ->
            <<"INSERT">>;
        update ->
            <<"UPSERT">>
    end,
    ActorsQuery = [
        Verb, <<" INTO actors">>,
        <<" (uid,srv,class,actor_type,name,vsn,data,metadata,path,last_update,expires,fts_words)">>,
        <<" VALUES ">>, nklib_util:bjoin(ActorFields), ?RETURN_NOTHING
    ],
    LabelsQuery = [
        <<"DELETE FROM labels WHERE uid IN ">>, UIDs, ?RETURN_NOTHING,
        case LabelFields of
            [] ->
                [];
            _ ->
                [
                    <<"UPSERT INTO labels (uid,label_key,label_value,path) VALUES ">>,
                    nklib_util:bjoin(LabelFields), ?RETURN_NOTHING
                ]
        end
    ],
    LinksQuery = [
        <<"DELETE FROM links WHERE uid IN ">>, UIDs, ?RETURN_NOTHING,
        case LinkFields of
            [] ->
                [];
            _ ->
                [
                    <<"UPSERT INTO links (uid,link_type,link_target,path) VALUES ">>,
                    nklib_util:bjoin(LinkFields), ?RETURN_NOTHING
                ]
        end
    ],
    FtsQuery = [
        <<"DELETE FROM fts WHERE uid IN ">>, UIDs, ?RETURN_NOTHING,
        case FtsFields of
            [] ->
                [];
            _ ->
                [
                    <<"UPSERT INTO fts (uid,fts_word,fts_field,path) VALUES ">>,
                    nklib_util:bjoin(FtsFields), ?RETURN_NOTHING
                ]
        end
    ],

    Query = [
        <<"BEGIN;">>,
        ActorsQuery,
        LabelsQuery,
        LinksQuery,
        FtsQuery,
        <<"COMMIT;">>
    ],
    case query(SrvId, PackageId, Query, #{auto_rollback=>true}) of
        {ok, _, SaveMeta} ->
            {ok, SaveMeta};
        {error, foreign_key_violation} ->
            {error, linked_actor_unknown};
        {error, Error} ->
            {error, Error}
    end.


%% @private
populate_fields([], #save_fields{uids=UIDs}=SaveFields) ->
    UIDs2 = list_to_binary([<<"(">>, nklib_util:bjoin(UIDs, $,), <<")">>]),
    SaveFields#save_fields{uids=UIDs2};

populate_fields([Actor|Rest], SaveFields) ->
    #save_fields{
        uids = UIDs,
        actors = Actors,
        labels = Labels,
        links = Links,
        fts = Fts
    } = SaveFields,
    #actor{
        id = #actor_id{
            uid = UID,
            srv = ActorSrvId,
            class = Class,
            type = Type,
            name = Name
        },
        vsn = Vsn,
        data = Data,
        metadata = Meta
    } = Actor,
    true = is_binary(UID) andalso UID /= <<>>,
    Path = nkservice_actor_util:make_reversed_srv_id(ActorSrvId),
    QUID = quote(UID),
    QPath = quote(Path),
    Updated = maps:get(<<"updateTime">>, Meta),
    Expires = case maps:get(<<"expiresTime">>, Meta, <<>>) of
        <<>> ->
            <<"NULL">>;
        Exp1 ->
            {ok, Exp2} = nklib_date:to_epoch(Exp1, secs),
            Exp2
    end,
    FtsWords1 = maps:fold(
        fun(Key, Text, Acc) ->
            Acc#{Key => nkservice_actor_util:fts_normalize_multi(Text)}
        end,
        #{},
        maps:get(<<"fts">>, Meta, #{})),
    FtsWords2 = maps:fold(
        fun(Key, Values, Acc1) ->
            lists:foldl(
                fun(Value, Acc2) ->
                    [<<" ">>, to_bin(Key), $:, to_bin(Value) | Acc2]
                end,
                Acc1,
                Values)
        end,
        [],
        FtsWords1),
    ActorFields = quote_list([
        UID,
        ActorSrvId,
        Class,
        Type,
        Name,
        Vsn,
        Data,
        Meta,
        Path,
        Updated,
        Expires,
        [FtsWords2, <<" ">>]
    ]),
    Actors2 = [list_to_binary([<<"(">>, ActorFields, <<")">>]) | Actors],
    Labels2 = maps:fold(
        fun(Key, Val, Acc) ->
            L = list_to_binary([
                <<"(">>, QUID, $,, quote(Key), $,, quote(to_bin(Val)), $,, QPath, <<")">>
            ]),
            [L|Acc]
        end,
        Labels,
        maps:get(<<"labels">>, Meta, #{})),
    Links2 = maps:fold(
        fun(LinkType, UID2, Acc) ->
            L = list_to_binary([
                <<"(">>, QUID, $,, quote(LinkType), $,, quote(UID2), $,, QPath, <<")">>
            ]),
            [L|Acc]
        end,
        Links,
        maps:get(<<"links">>, Meta, #{})),
    Fts2 = maps:fold(
        fun(Field, WordList, Acc1) ->
            lists:foldl(
                fun(Word, Acc2) ->
                    L = list_to_binary([
                        <<"(">>, QUID, $,, quote(Word), $,, quote(Field), $,, QPath, <<")">>
                    ]),
                    [L|Acc2]
                end,
                Acc1,
                WordList)
        end,
        Fts,
        FtsWords1),
    SaveFields2 = SaveFields#save_fields{
        uids = [QUID|UIDs],
        actors = Actors2,
        labels = Labels2,
        links = Links2,
        fts = Fts2
    },
    populate_fields(Rest, SaveFields2).


%% @doc
%% Option 'cascade' to delete all linked
delete(SrvId, PackageId, UID, Opts) when is_binary(UID) ->
    delete(SrvId, PackageId, [UID], Opts);

delete(SrvId, PackageId, UIDs, Opts) ->
    Debug = nkservice_util:get_debug(SrvId, nkservice_pgsql, PackageId, debug),
    QueryMeta = #{pgsql_debug=>Debug},
    QueryFun = fun(Pid) ->
        do_query(Pid, <<"BEGIN;">>, QueryMeta),
        {ActorIds, DelQ} = case Opts of
            #{cascade:=true} ->
                NestedUIDs = delete_find_nested(Pid, UIDs, sets:new()),
                ?LLOG(notice, "DELETE on CASCADE: ~p", [NestedUIDs]),
                delete_actors(NestedUIDs, false, Pid, QueryMeta, [], []);
            _ ->
                delete_actors(UIDs, true, Pid, QueryMeta, [], [])
        end,
        do_query(Pid, DelQ, QueryMeta),
        do_query(Pid, <<"COMMIT;">>, QueryMeta#{deleted_actor_ids=>ActorIds})
    end,
    case query(SrvId, PackageId, QueryFun, #{}) of
        {ok, _, Meta1} ->
            {ActorIds2, Meta2} = maps:take(deleted_actor_ids, Meta1),
            {ok, ActorIds2, Meta2};
        {error, Error} ->
            {error, Error}
    end.


%% @private Returns the list of UIDs an UID depends on
delete_find_nested(_Pid, [], Set) ->
    sets:to_list(Set);

delete_find_nested(Pid, [UID|Rest], Set) ->
    case sets:is_element(UID, Set) of
        true ->
            delete_find_nested(Pid, Rest, Set);
        false ->
            Set2 = sets:add_element(UID, Set),
            case sets:size(Set2) > 5 of
                true ->
                    throw(delete_too_deep);
                false ->
                    Q = [<<" SELECT uid FROM links WHERE link_target=">>, quote(UID), <<";">>],
                    Childs = case do_query(Pid, Q, #{}) of
                        {ok, [[]], _} ->
                            [];
                        {ok, [List], _} ->
                            [U || {U} <- List]
                    end,
                    delete_find_nested(Pid, Childs++Rest, Set2)
            end
    end.


%% @private
delete_actors([], _CheckChilds, _Pid, _QueryMeta, ActorIds, QueryAcc) ->
    {ActorIds, QueryAcc};

delete_actors([UID|Rest], CheckChilds, Pid, QueryMeta, ActorIds, QueryAcc) ->
    nkservice_actor_srv:raw_stop(UID, pre_delete),
    QUID = quote(UID),
    case CheckChilds of
        true ->
            LinksQ = [<<"SELECT uid FROM links WHERE link_target=">>, QUID, <<";">>],
            case do_query(Pid, LinksQ, QueryMeta) of
                {ok, [[]], _} ->
                    ok;
                _ ->
                    throw(actor_has_linked_actors)
            end;
        false ->
            ok
    end,
    GetQ = [
        <<"SELECT srv,class,actor_type,name FROM actors ">>,
        <<"WHERE uid=">>, quote(UID), <<";">>
    ],
    case do_query(Pid, GetQ, QueryMeta) of
        {ok, [[{ActorSrvId, Class, Type, Name}]], _} ->
            ActorId = #actor_id{
                srv = get_srv(ActorSrvId),
                uid = UID,
                class = Class,
                type = Type,
                name = Name,
                pid = undefined
            },
            QueryAcc2 = [
                <<"DELETE FROM actors WHERE uid=">>, QUID, ?RETURN_NOTHING,
                <<"DELETE FROM labels WHERE uid=">>, QUID, ?RETURN_NOTHING,
                <<"DELETE FROM links WHERE uid=">>, QUID, ?RETURN_NOTHING,
                <<"DELETE FROM fts WHERE uid=">>, QUID, ?RETURN_NOTHING
                | QueryAcc
            ],
            delete_actors(Rest, CheckChilds, Pid, QueryMeta, [ActorId|ActorIds], QueryAcc2);
        {ok, [[]], _} ->
            throw(actor_not_found);
        {error, Error} ->
            throw(Error)
    end.


%% @doc
search(SrvId, PackageId, SearchType, Opts) ->
    case ?CALL_SRV(SrvId, actor_db_get_query, [pgsql, SearchType, Opts]) of
        {ok, {pgsql, Query, QueryMeta}} ->
            query(SrvId, PackageId, Query, QueryMeta);
        {error, Error} ->
            {error, Error}
    end.


%% @doc
aggregation(SrvId, PackageId, SearchType, Opts) ->
    case ?CALL_SRV(SrvId, actor_db_get_query, [pgsql, SearchType, Opts]) of
        {ok, {pgsql, Query, QueryMeta}} ->
            case query(SrvId, PackageId, Query, QueryMeta) of
                {ok, [Res], Meta} ->
                    case (catch maps:from_list(Res)) of
                        {'EXIT', _} ->
                            {error, aggregation_invalid};
                        Map ->
                            {ok, Map, Meta}
                    end;
                {ok, _, _} ->
                    {error, aggregation_invalid};
                {error, Error} ->
                    {error, Error}
            end;
        {error, Error} ->
            {error, Error}
    end.


%% @doc
get_service(SrvId, PackageId, ActorSrvId) ->
    Query = [
        <<"SELECT cluster,node,last_update,pid FROM services ">>,
        <<" WHERE srv=">>, quote(ActorSrvId), <<";">>
    ],
    case query(SrvId, PackageId, Query) of
        {ok, [[Fields]], QueryMeta} ->
            {Cluster, Node, Updated, Pid} = Fields,
            Reply = #{
                cluster => Cluster,
                node => nklib_util:make_atom(?MODULE, Node),
                updated => Updated,     % 3339
                pid => list_to_pid(binary_to_list(Pid))
            },
            {ok, Reply, QueryMeta};
        {ok, [[]], _QueryMeta} ->
            {error, service_not_found};
        {error, Error} ->
            {error, Error}
    end.


%% @doc
update_service(SrvId, PackageId, ActorSrvId, Cluster) ->
    {ok, Update} = nklib_date:to_3339(nklib_date:epoch(secs)),
    Pid2 = quote(list_to_binary(pid_to_list(self()))),
    Query = [
        <<"UPSERT INTO services (srv,cluster,node,last_update,pid) VALUES (">>,
        quote(ActorSrvId), $,, quote(Cluster), $,,  quote(node()), $,, Update, $,, Pid2,
        <<");">>
    ],
    case query(SrvId, PackageId, Query) of
        {ok, _, QueryMeta} ->
            {ok, QueryMeta};
        {error, Error} ->
            {error, Error}
    end.


%% @doc Gets, for an UID, all links it has to other objects
%% Returns {Type, UID}
get_links(SrvId, PackageId, UID, Type) ->
    UID2 = to_bin(UID),
    Query = [
        <<"SELECT type,uid2 FROM links">>,
        <<" WHERE uid1=">>, quote(UID2),
        case Type of
            <<>> ->
                <<>>;
            _ ->
                [<<" AND type=">>, quote(Type)]
        end,
        <<";">>
    ],
    case query(SrvId, PackageId, Query, #{}) of
        {ok, [List], Meta} ->
            {ok, List, Meta};
        {error, Error} ->
            {error, Error}
    end.


%% @doc
%% Returns {Type, UID}
get_linked(SrvId, PackageId, UID, Type) ->
    UID2 = to_bin(UID),
    Query = [
        <<"SELECT type,uid1 FROM links">>,
        <<" WHERE uid2=">>, quote(UID2),
        case Type of
            <<>> ->
                <<>>;
            _ ->
                [<<" AND type=;">>, quote(Type)]
        end,
        <<";">>
    ],
    case query(SrvId, PackageId, Query, #{}) of
        {ok, [List], Meta} ->
            {ok, List, Meta};
        {error, Error} ->
            {error, Error}
    end.



%% ===================================================================
%% Internal
%% ===================================================================

%% @private
query(SrvId, PackageId, Query) ->
    query(SrvId, PackageId, Query, #{}).


%% @private
query(SrvId, PackageId, Query, QueryMeta) ->
    Debug = nkservice_util:get_debug(SrvId, nkservice_pgsql, PackageId, debug),
    QueryMeta2 = QueryMeta#{pgsql_debug=>Debug},
    case nkservice_pgsql:get_connection(SrvId, PackageId) of
        {ok, Pid} ->
            try
                {ok, Data, MetaData}= case is_function(Query, 1) of
                    true ->
                        Query(Pid);
                    false ->
                        do_query(Pid, Query, QueryMeta2)
                end,
                {ok, Data, MetaData}
            catch
                throw:Throw ->
                    % Processing 'user' errors
                    % If we are on a transaction, and some line fails,
                    % it will abort but we need to rollback to be able to
                    % reuse the connection
                    case QueryMeta2 of
                        #{auto_rollback:=false} ->
                            ok;
                        _ ->
                            case catch do_query(Pid, <<"ROLLBACK;">>, #{pgsql_debug=>Debug}) of
                                {ok, _, _} ->
                                    ok;
                                no_transaction ->
                                    ok;
                                Error ->
                                    ?LLOG(notice, "error performing Rollback: ~p", [Error]),
                                    error(rollback_error)
                            end
                    end,
                    {error, Throw};
                Class:CError ->
                    % For other errors, we better close the connection
                    ?LLOG(warning, "error in query: ~p, ~p, ~p", [Class, CError, erlang:get_stacktrace()]),
                    nkservice_pgsql:stop_connection(Pid),
                    {error, internal_error}
            after
                nkservice_pgsql:release_connection(SrvId, PackageId, Pid)
            end;
        {error, Error} ->
            {error, Error}
    end.


%% @private
do_query(Pid, Query, QueryMeta) when is_pid(Pid) ->
    % ?LLOG(info, "PreQuery: ~s", [Query]),
    case nkservice_pgsql:do_query(Pid, Query) of
        {ok, Ops, PgMeta} ->
            case maps:get(pgsql_debug, QueryMeta, false) of
                true ->
                    ?LLOG(notice, "Query: ~s\n~p", [Query, PgMeta]),
                    ok;
                _ ->
                    ok
            end,
            % lager:error("NKLOG OPS ~p", [Ops]),
            case QueryMeta of
                #{result_fun:=ResultFun} ->
                    ResultFun(Ops, QueryMeta#{pgsql=>PgMeta});
                _ ->
                    L = [Rows || {_Op, Rows, _OpMeta} <- Ops],
                    {ok, L, QueryMeta#{pgsql=>PgMeta}}
            end;
        {error, {pgsql_error, #{routine:=<<"NewUniquenessConstraintViolationError">>}}} ->
            throw(uniqueness_violation);
        {error, {pgsql_error, #{code := <<"23503">>}}} ->
            throw(foreign_key_violation);
        {error, {pgsql_error, #{code := <<"XX000">>}}=Error} ->
            ?LLOG(warning, "no_transaction PGSQL error: ~p\n~s", [Error, list_to_binary([Query])]),
            throw(no_transaction);
        {error, {pgsql_error, #{code := <<"42P01">>}}} ->
            throw(relation_unknown);
        {error, {pgsql_error, #{code := <<"42601">>}}=Error} ->
            ?LLOG(warning, "syntax PGSQL error: ~p\n~s", [Error, list_to_binary([Query])]),
            throw(pgsql_error);
        {error, {pgsql_error, Error}} ->
            ?LLOG(warning, "unknown PGSQL error: ~p\n~s", [Error, list_to_binary([Query])]),
            throw(pgsql_error);
        {error, Error} ->
            throw(Error)
    end.



quote_list(List) ->
    nkservice_pgsql_util:quote_list(List).


%% @private
get_srv(ActorSrvId) ->
    nkservice_actor_util:gen_srv_id(ActorSrvId).


%% @private
quote(Field) ->
    nkservice_pgsql_util:quote(Field).


%% @private
to_bin(Term) when is_binary(Term) -> Term;
to_bin(Term) -> nklib_util:to_binary(Term).



