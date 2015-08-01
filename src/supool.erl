%-*-Mode:erlang;coding:utf-8;tab-width:4;c-basic-offset:4;indent-tabs-mode:()-*-
% ex: set ft=erlang fenc=utf-8 sts=4 ts=4 sw=4 et nomod:
%%%
%%%------------------------------------------------------------------------
%%% @doc
%%% ==Supervisor Pool==
%%% Simple supervisor process pool with round-robin.
%%% @end
%%%
%%% BSD LICENSE
%%% 
%%% Copyright (c) 2011-2015, Michael Truog <mjtruog at gmail dot com>
%%% All rights reserved.
%%% 
%%% Redistribution and use in source and binary forms, with or without
%%% modification, are permitted provided that the following conditions are met:
%%% 
%%%     * Redistributions of source code must retain the above copyright
%%%       notice, this list of conditions and the following disclaimer.
%%%     * Redistributions in binary form must reproduce the above copyright
%%%       notice, this list of conditions and the following disclaimer in
%%%       the documentation and/or other materials provided with the
%%%       distribution.
%%%     * All advertising materials mentioning features or use of this
%%%       software must display the following acknowledgment:
%%%         This product includes software developed by Michael Truog
%%%     * The name of the author may not be used to endorse or promote
%%%       products derived from this software without specific prior
%%%       written permission
%%% 
%%% THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND
%%% CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES,
%%% INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
%%% OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
%%% DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR
%%% CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
%%% SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
%%% BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
%%% SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
%%% INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
%%% WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
%%% NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
%%% OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH
%%% DAMAGE.
%%%
%%% @author Michael Truog <mjtruog [at] gmail (dot) com>
%%% @copyright 2011-2015 Michael Truog
%%% @version 1.5.1 {@date} {@time}
%%%------------------------------------------------------------------------

-module(supool).
-author('mjtruog [at] gmail (dot) com').

-behaviour(gen_server).

%% external interface
-export([start_link/3,
         start_link/4,
         get/1]).

%% internal interface
-export([pool_worker_start_link/4]).

%% gen_server callbacks
-export([init/1,
         handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include("supool_logging.hrl").

-record(state,
    {
        pool,
        count,
        supervisor
    }).

-type options() ::
    list({max_r, non_neg_integer()} |
         {max_t, pos_integer()}).
-type child_spec() ::
    {Id :: any(),
     StartFunc :: {module(), atom(), list()},
     Restart :: permanent | transient | temporary,
     Shutdown :: brutal_kill | pos_integer(),
     Type :: worker | supervisor,
     Modules :: [module()] | dynamic}.
-export_type([options/0,
              child_spec/0]).

%%%------------------------------------------------------------------------
%%% External interface functions
%%%------------------------------------------------------------------------

%%-------------------------------------------------------------------------
%% @doc
%% ===Start the pool supervisor.===
%% @end
%%-------------------------------------------------------------------------

-spec start_link(Name :: atom(),
                 Count :: pos_integer(),
                 ChildSpec :: child_spec()) ->
    {ok, pid()} |
    {error, any()}.

start_link(Name, Count, ChildSpec) ->
    supool_sup:start_link(Name, Count, ChildSpec, []).

%%-------------------------------------------------------------------------
%% @doc
%% ===Start the pool supervisor with restart options.===
%% @end
%%-------------------------------------------------------------------------

-spec start_link(Name :: atom(),
                 Count :: pos_integer(),
                 ChildSpec :: child_spec(),
                 Options :: options()) ->
    {ok, pid()} |
    {error, any()}.

start_link(Name, Count, ChildSpec, Options) ->
    supool_sup:start_link(Name, Count, ChildSpec, Options).

%%-------------------------------------------------------------------------
%% @doc
%% ===Get a pool process.===
%% @end
%%-------------------------------------------------------------------------

-spec get(Name :: atom()) ->
    pid() | undefined.

get(Name)
    when is_atom(Name) ->
    try gen_server:call(Name, get, infinity)
    catch
        exit:{noproc, _} ->
            undefined
    end.

%%%------------------------------------------------------------------------
%%% Internal interface functions
%%%------------------------------------------------------------------------

-spec pool_worker_start_link(Name :: atom(),
                             ChildSpecs :: nonempty_list(child_spec()),
                             Supervisor :: pid(),
                             Parent :: pid()) ->
    {ok, pid()} |
    {error, any()}.

pool_worker_start_link(Name, [_ | _] = ChildSpecs, Supervisor, Parent)
    when is_atom(Name), is_list(ChildSpecs), is_pid(Supervisor),
         is_pid(Parent) ->
    gen_server:start_link({local, Name}, ?MODULE,
                          [ChildSpecs, Supervisor, Parent], []).

%%%------------------------------------------------------------------------
%%% Callback functions from gen_server
%%%------------------------------------------------------------------------

init([ChildSpecs, Supervisor, Parent]) ->
    self() ! {start, ChildSpecs},
    supool_sup:start_link_done(Parent),
    {ok, #state{supervisor = Supervisor}}.

handle_call(get, _, #state{pool = Pool,
                           count = Count} = State) ->
    I = erlang:get(current),
    erlang:put(current, if I == Count -> 1; true -> I + 1 end),
    Pid = erlang:element(I, Pool),
    case erlang:is_process_alive(Pid) of
        true ->
            {reply, Pid, State};
        false ->
            {NewI, NewState} = update(I, State),
            if
                NewState#state.count == 0 ->
                    {stop, {error, noproc}, undefined, NewState};
                true ->
                    {reply, erlang:element(NewI, NewState#state.pool), NewState}
            end
    end;

handle_call(Request, _, State) ->
    ?LOG_WARN("Unknown call \"~p\"", [Request]),
    {stop, lists:flatten(io_lib:format("Unknown call \"~p\"", [Request])),
     error, State}.

handle_cast(Request, State) ->
    ?LOG_WARN("Unknown cast \"~p\"", [Request]),
    {noreply, State}.

handle_info({start, ChildSpecs}, #state{supervisor = Supervisor} = State) ->
    case supool_sup:start_children(Supervisor, ChildSpecs) of
        {ok, []} ->
            {stop, {error, noproc}, State};
        {ok, Pids} ->
            erlang:put(current, 1),
            {noreply, State#state{pool = erlang:list_to_tuple(Pids),
                                  count = erlang:length(Pids)}};
        {error, _} = Error ->
            {stop, Error, State}
    end;

handle_info(Request, State) ->
    ?LOG_WARN("Unknown info \"~p\"", [Request]),
    {noreply, State}.

terminate(_, _) ->
    ok.

code_change(_, State, _) ->
    {ok, State}.

%%%------------------------------------------------------------------------
%%% Private functions
%%%------------------------------------------------------------------------

update(I, #state{supervisor = Supervisor} = State) ->
    Pids = supool_sup:which_children(Supervisor),
    Count = erlang:length(Pids),
    NewState = State#state{pool = erlang:list_to_tuple(Pids),
                           count = Count},
    if
        I > Count ->
            erlang:put(current, if 1 == Count -> 1; true -> 2 end),
            {1, NewState};
        true ->
            {I, NewState}
    end.

