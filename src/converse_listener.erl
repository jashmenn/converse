-module (converse_listener).
-include ("converse.hrl").

-behaviour(gen_server).

-record(state,{	listen_socket = [],
								accept_pid = null,
								tcp_acceptor = null,
								successor = undefined,
								config = 0}).

%% External API
-export([start_link/1,create/2]).
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).

%%--------------------------------------------------------------------
%% @spec (Port::integer(), Module) -> {ok, Pid} | {error, Reason}
%
%% @doc Called by a supervisor to start the listening process.
%% @end
%%----------------------------------------------------------------------
start_link(Config) ->	
	gen_server:start_link({local, ?MODULE}, ?MODULE, [Config], []).

create(ServerPid, Pid) ->
	gen_server:cast(ServerPid, {create, Pid}).
				
%%%------------------------------------------------------------------------
%%% Callback functions from gen_server
%%%------------------------------------------------------------------------

%%----------------------------------------------------------------------
%% @spec (Port::integer()) -> {ok, State}           |
%%                            {ok, State, Timeout}  |
%%                            ignore                |
%%                            {stop, Reason}
%%
%% @doc Called by gen_server framework at process startup.
%%      Create listening socket.
%% @end
%%----------------------------------------------------------------------
init([Config]) ->
    process_flag(trap_exit, true),
		
		[Opts, Port,Successor] = config:fetch_or_default_config([sock_opts,port,successor], Config, ?DEFAULT_CONFIG),

    case gen_tcp:listen(Port, Opts) of
    {ok, Sock} ->
        %%Create first accepting process
        {ok, Ref} = prim_inet:async_accept(Sock, -1),
        {ok, #state{listen_socket = Sock,
										tcp_acceptor = Ref,
										config = Config,
                    successor = Successor}};
    {error, Reason} ->
        {stop, Reason}
    end.

%%-------------------------------------------------------------------------
%% @spec (Request, From, State) -> {reply, Reply, State}          |
%%                                 {reply, Reply, State, Timeout} |
%%                                 {noreply, State}               |
%%                                 {noreply, State, Timeout}      |
%%                                 {stop, Reason, Reply, State}   |
%%                                 {stop, Reason, State}
%% @doc Callback for synchronous server calls.  If `{stop, ...}' tuple
%%      is returned, the server is stopped and `terminate/2' is called.
%% @end
%% @private
%%-------------------------------------------------------------------------		
handle_call(Request, _From, State) ->
    {stop, {unknown_call, Request}, State}.

%%-------------------------------------------------------------------------
%% @spec (Msg, State) ->{noreply, State}          |
%%                      {noreply, State, Timeout} |
%%                      {stop, Reason, State}
%% @doc Callback for asyncrous server calls.  If `{stop, ...}' tuple
%%      is returned, the server is stopped and `terminate/2' is called.
%% @end
%% @private
%%-------------------------------------------------------------------------	
handle_cast({create,Pid,CliSocket}, #state{listen_socket=ListSock, tcp_acceptor=Ref, config=Config} = State) ->
	NewPid = case converse_app:start_tcp_client(Config) of
		{ok, P} -> P;
		{error, {already_started, P}} -> P;
		{error, R} -> 
			io:format("Error starting tcp client ~p~n", [R]),
			exit({error, R})
	end,
  gen_tcp:controlling_process(CliSocket, NewPid),
  converse_tcp:set_socket(NewPid, CliSocket),

  case prim_inet:async_accept(ListSock, -1) of
    {ok, NewRef} -> ok;
		{error, NewRef} -> exit({async_accept, inet:format_error(NewRef)})
	end,
	{noreply, State#state{accept_pid=NewPid}};
	
handle_cast(_Msg, State) ->
	{noreply, State}.

%%-------------------------------------------------------------------------
%% @spec (Msg, State) ->{noreply, State}          |
%%                      {noreply, State, Timeout} |
%%                      {stop, Reason, State}
%% @doc Callback for messages sent directly to server's mailbox.
%%      If `{stop, ...}' tuple is returned, the server is stopped and
%%      `terminate/2' is called.
%% @end
%% @private
%%-------------------------------------------------------------------------	
handle_info({inet_async, ListSock, Ref, {ok, CliSocket}},
            #state{listen_socket=ListSock, tcp_acceptor=Ref, config=Config} = State) ->
	try
		case set_sockopt(ListSock, CliSocket) of
			ok -> ok;
			{error, Reason} -> 
				exit({set_sockopt, Reason})
	  end,

    Pid = case converse_app:start_tcp_client(Config) of
			{ok, P} -> P;
			{error, {already_started, P}} -> P;
			{error, R} -> 
				io:format("Error starting tcp client ~p~n", [R]),
				exit({error, R})
		end,
    gen_tcp:controlling_process(CliSocket, Pid),
    converse_tcp:set_socket(Pid, CliSocket),

    %% Signal the network driver that we are ready to accept another connection
    case prim_inet:async_accept(ListSock, -1) of
	    {ok, NewRef} -> ok;
			{error, NewRef} -> exit({async_accept, inet:format_error(NewRef)})
		end,
		{noreply, State#state{tcp_acceptor=NewRef}}
		
	catch exit:Why ->
		error_logger:error_msg("Error in async accept: ~p.\n", [Why]),
		{stop, Why, State}
	end;

handle_info({inet_async, ListSock, Ref, Error}, #state{listen_socket=ListSock, tcp_acceptor=Ref} = State) ->
	error_logger:error_msg("Error in socket tcp_acceptor: ~p.\n", [Error]),
	{stop, Error, State};

handle_info({'EXIT', _ListSock, _Ref, Error}, State) ->
	error_logger:error_msg("Error in socket tcp_acceptor: ~p.\n", [Error]),
	{noreply, State};

handle_info(Info, State) ->
	io:format("Received info", [Info]),
  {noreply, State}.

%%-------------------------------------------------------------------------
%% @spec (Reason, State) -> any
%% @doc  Callback executed on server shutdown. It is only invoked if
%%       `process_flag(trap_exit, true)' is set by the server process.
%%       The return value is ignored.
%% @end
%% @private
%%-------------------------------------------------------------------------
terminate(_Reason, State) ->
    gen_tcp:close(State#state.listen_socket),
    ok.

%%-------------------------------------------------------------------------
%% @spec (OldVsn, State, Extra) -> {ok, NewState}
%% @doc  Convert process state when code is changed.
%% @end
%% @private
%%-------------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%------------------------------------------------------------------------
%%% Internal functions
%%%------------------------------------------------------------------------

set_sockopt(ListSock, CliSocket) ->
    true = inet_db:register_socket(CliSocket, inet_tcp),
    case prim_inet:getopts(ListSock, [active, nodelay, keepalive, delay_send, priority, tos]) of
    {ok, Opts} ->
        case prim_inet:setopts(CliSocket, Opts) of
        ok    -> ok;
        Error -> gen_tcp:close(CliSocket), Error
        end;
    Error ->
        gen_tcp:close(CliSocket), Error
    end.