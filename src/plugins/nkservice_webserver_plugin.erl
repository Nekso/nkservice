%% -------------------------------------------------------------------
%%
%% Copyright (c) 2017 Carlos Gonzalez Florido.  All Rights Reserved.
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

%% @doc Default callbacks
-module(nkservice_webserver_plugin).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-export([plugin_deps/0, plugin_config/2, plugin_listen/2]).


%% ===================================================================
%% Plugin Callbacks
%% ===================================================================

plugin_deps() ->
	[].


plugin_config(Config, _Service) ->
    Syntax = #{
        servers => {list, #{
            id => binary,
            url => fun nkservice_webserver_util:parse_url/1,
            file_path => binary,
            opts => nkpacket_syntax:safe_syntax(),
            '__mandatory' => [id, url]
        }}
    },
    case nklib_syntax:parse(Config, Syntax) of
        {ok, Parsed, _} ->
            {ok, Parsed};
        {error, Error} ->
            {error, Error}
    end.


plugin_listen(Config, #{id:=SrvId}) ->
    Endpoints = maps:get(nkservice_webserver, Config, []),
    nkservice_webserver_util:make_listen(SrvId, Endpoints).


