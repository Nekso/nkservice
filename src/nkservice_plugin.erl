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

%% @doc Default callbacks for plugin definitions
-module(nkservice_plugin).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-export([plugin_deps/0, plugin_group/0, 
	     plugin_syntax/0, plugin_config/2,
		 plugin_start/2, plugin_update/2, plugin_stop/2]).
-export_type([continue/0]).

-type continue() :: continue | {continue, list()}.
-type spec() :: nkservice:spec().
-type service() :: nkservice:service().


%% ===================================================================
%% Plugin Callbacks
%% ===================================================================



%% @doc Called to get the list of plugins this service/plugin depends on.
-spec plugin_deps() ->
    [module()].

plugin_deps() ->
	[].


%% @doc Optionally set the plugin 'group'
%% All plugins within a group are added a dependency on the previous defined plugins
%% in the same group.
%% This way, the order of callbacks is the same as the order plugins are defined
%% in this group.
-spec plugin_group() ->
    term() | undefined.

plugin_group() ->
	undefined.


%% @doc This function, if implemented, can offer a nklib_config:syntax()
%% that will be checked against service configuration. Entries passing will be
%% updated on the configuration with their parsed values
-spec plugin_syntax() ->
	nklib_config:syntax().

plugin_syntax() ->
	#{}.


%% @doc This function can modify the service configuration, and can also
%% generate a specific plugin configuration (in the second return), that will be 
%% accessible in the generated module as config_(plugin_name).
%% Top-level plugins will be called first, so they can set up configurations for low-level
-spec plugin_config(PluginConfig::map(), service()) ->
	ok | {ok, service()} | {error, term()}.

plugin_config(_Config, _Service) ->
	ok.


%% @doc Called during service's start
%% The plugin must start and can update the service's config
-spec plugin_start(spec(), service()) ->
	{ok, spec()} | {error, term()}.

plugin_start(Config, _Service) ->
	{ok, Config}.


%% @doc Called during service's update
-spec plugin_update(spec(), service()) ->
	{ok, spec()} | {error, term()}.

plugin_update(Config, _Service) ->
	{ok, Config}.


%% @doc Called during service's stop
%% The plugin must remove any key from the service
-spec plugin_stop(spec(), service()) ->
	{ok, spec()}.

plugin_stop(Config, _Service) ->
	{ok, Config}.

