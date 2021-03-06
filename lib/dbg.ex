defmodule Dbg do
  @moduledoc """
  `Dbg` provides functions for tracing events in the BEAM VM.

  Many events, including function calls and return, exception raising, sending
  and receiving messages, spawning, exiting, linking, scheduling and garbage
  collection can be traced across a cluster of nodes using `Dbg`.

  ## Configuration

  To configure the output `device` for `Dbg` the `Application` env variable
  `:device` to an `IO.device` or `{:file, Path.t}`. In the later case a binary
  format is used to write to the file that can be read later using
  `Dbg.inspect_file/2`. The default is to send output to the `:user` process.

  When outputting to an `IO.device`, or when reading a binary trace file, the
  colours and inspection of terms use `IEx`'s configuration. `Dbg` uses two
  extra colour settings not supported by `IEx`:

    * `trace_info` - the colour used to print trace messages
    * `trace_app` - the colour to print application names in stacktraces

  These are configured like the other `IEx` colour settings. The default is to
  print in `magenta`, with application names `bright,magenta` in stacktraces.
  """

  @compile {:parse_transform, :ms_transform}

  @typep process :: pid | atom | { :global, term} | { atom, node } |
    { :via, module, term }
  @typep item :: :all | :new | :existing | process
  @typep flag :: :s | :r | :m | :messages | :c | :p | :sos | :sofs | :sol |
    :sofl | native_flag
   @typep native_flag :: :all | :send | :receive | :procs | :call | :silent |
    :return_to | :running | :garbage_collection | :timestamp |
    :arity | :set_on_spawn | :set_on_first_spawn |
    :set_on_link | :set_on_first_link
  @typep option :: :return | :exception | :stack | :caller |
    { :silent, boolean } | { :trace, [flag], [flag]} |
    { :trace, pid | {:self}, [flag], [flag]} | :clear |
    { :clear, pid | {:self} }
  @typep fun_call :: fun | module | { module, atom, arity } | { module, atom }
  @typep id :: nil | pos_integer | :c | :x | :cx
  @typep pattern :: fun | Dbg.MatchSpec.t | String.t | id | option | [option]

  @doc """
  Turns on tracing `flags` for `item`.

  `item` takes one of the following forms:

    * `:all` - all current and future pirocesses
    * `:new` - all future processes
    * `:existing` -all current processes
    * `pid` - a process
    * `atom` - a locally registered process
    * `{atom, node}` - a locally registered process on another node
    * `{:global, term}` - a globally registered process
    * `{:via, module, term}` - a process registered using a `:via` module

  `flags` is a list or a single `flag`:

    * `:send` (or `:s`) - will trace all messages sent by the `item`
    * `:receive` (or `:r`) - will trace all messages received by the `item`
    * `:messages` (or `:m`) - is the equivalent of `:send` and `:receive`
    * `:call` (or `:c`) - will turn on call tracing (see `call/2`) for the
  `item`
    * `:arity` - used in combination with `:call` will not include function
  arguments in the `item`'s call trace events
    * `:return_to` - used in combination with `:call` will show which function
  (and when) a call returns to
    * `:silent` - used in combination with `:call` will hide all the `item`'s
  call trace events
    * `:procs` (or `:p`) - will trace all process events by the `item`
    * `:running` - will trace when the `item` is scheduled in and out
    * `:garbage_collection` - will trace garbage collection events by the `item`
    * `:set_on_spawn` (or `:sos`) - will cause processes spawned by the `item`
  to in herit the `item`'s trace flags
    * `:set_on_first_spawn` (or `:sofs`) - will cause the first process spawned
  by the `item` to in herit the `item`'s trace flags.
    * `:set_on_link` (or `:sol`) - will cause a process linked to by the `item`
  to inherit the `item`'s trace flags
    * `:set_on_first_link` (or `:sofl`) - will cause the first process linked to
  by the `item` to inherit the `item`'s trace flags
    * `:timestamp` - will add a timestamp to all of the `item`'s traced events

  For example:

      # Trace all messages of self(), and any messages for processes it spawns
      Dbg.trace([:messages, :set_on_spawn])

      # Turn on call tracing for process registered as :name but don't include
      # function arguments
      Dbg.trace(:name, [:call, :arity])

      # Trace the scheduling of :name on node :node@host including the time
      Dbg.trace({:name, :node@host}, [:running, :timestamp])
  """
  @spec trace(flag | [flag]) :: map
  @spec trace(item, flag | [flag]) :: map
  def trace(item \\ self(), flags)

  def trace(item, flags) when item in [:all, :new, :existing] or is_pid(item) do
    try do
      :dbg.p(item, Dbg.MatchSpec.transform_flags(flags))
    else
      {:ok, result} ->
        parse_result(result)
      {:error, reason} ->
        exit({reason, {__MODULE__, :trace, [item, flags]}})
    catch
      :exit, :dbg_server_crashed ->
        exit({:dbg_server_crashed, {__MODULE__, :trace, [item, flags]}})
    end
  end

  def trace(process, flags) do
    case whereis(process) do
      nil ->
        exit({:noproc, {__MODULE__, :trace, [process, flags]}})
      pid when is_pid(pid) ->
        try do
          :dbg.p(pid, Dbg.MatchSpec.transform_flags(flags))
        else
          {:ok, result} ->
            parse_result(result)
          {:error, reason} ->
            exit({reason, {__MODULE__, :trace, [process, flags]}})
        catch
          :exit, :dbg_server_crashed ->
            exit({:dbg_server_crashed, {__MODULE__, :trace, [process, flags]}})
        end
    end
  end

  @doc """
  Turns off all tracing flags for an `item`.

  For a list of `item`s see `trace/2`.

  For example:

      # Clear tracing flags from self()
      Dbg.clear()

      # Clear tracing flags from all processes
      Dbg.clear(:all)
  """
  @spec clear() :: map
  @spec clear(item) :: map
  def clear(item \\ self())

  def clear(item) when item in [:all, :new, :existing] or is_pid(item) do
    try do
      :dbg.p(item, :clear)
    else
      {:ok, result} ->
        parse_result(result)
      {:error, reason} ->
        exit({reason, {__MODULE__, :clear, [item]}})
    catch
      :exit, :dbg_server_crashed ->
        exit({:dbg_server_crashed, {__MODULE__, :clear, [item]}})
    end
  end

  def clear(process) do
    case whereis(process) do
      nil ->
        exit({:noproc, {__MODULE__, :clear, [process]}})
      pid when is_pid(pid) ->
        try do
          :dbg.p(pid, :clear)
        else
          {:ok, result} ->
            parse_result(result)
          {:error, reason} ->
            exit({reason, {__MODULE__, :clear, [process]}})
        catch
          :exit, :dbg_server_crashed ->
            exit({:dbg_server_crashed, {__MODULE__, :clear, [process]}})
        end
    end
  end

  @doc """
  Turns on tracing for processes on a foreign node by the local `Dbg` process.

  Can not add nodes whe tracing to file, consider using `Dbg` on the foreign
  node as well.

  For example:

      # Start tracing :node@host
      Dbg.node(:node@host)
  """
  @spec node(node) :: :ok
  def node(node_name) do
    try do
      :dbg.n(node_name)
    else
      {:ok, _node_name} -> :ok
      {:error, reason} -> exit({reason, {__MODULE__, :node, [node_name]}})
    catch
      :exit, :dbg_server_crash ->
        exit({:dbg_server_crash, {__MODULE__, :node, [node_name]}})
    end
  end


  @doc """
  Lists all nodes being traced by the local `Dbg` process.
  """
  @spec nodes() :: [node]
  def nodes() do
    case req(:get_nodes) do
      {:ok, nodes} -> nodes
      {:error, reason} -> exit({reason, {__MODULE__, :nodes, []}})
    end
  end

  @doc """
  Turns off tracing processes on a foreign node by the local `Dbg` process.

  For example:

      # Stop tracing :node@host
      Dbg.clear_node(:node@host)
  """
  @spec clear_node(node) :: :ok
  def clear_node(node_name) do
    try do
      :dbg.cn(node_name)
    catch
      :exit, :dbg_server_crash ->
        exit({:dbg_server_crash, {__MODULE__, :clear_node, [node_name]}})
    end
  end

  @doc """
  Set call tracing for global function calls.

  `target` takes one of the following forms:

    * `module` - traces all functions in the module
    * `{module, atom}` - trace all function's with the name in the module
    * `{module, atom, arity}` - trace the function name with arity in the module
    * `fun` - trace calls equivalent to fun (must be an external fun, e.g.
    `&module.fun/arity`)

  `pattern` takes one of the following forms:

    * `:c` - call traces will include the calling function where possible
    * `:x` - adds tracing of the return value or raising of the call
    * `:xc` - equivalent to :c and :x
    * `integer` - the `saved` id of a previous pattern
    * [`option`] or `option` - can be an empty list, see below
    * `match_spec` - see below

  `option` takes one of the following forms:

    * `:caller` - call traces will include the calling function where possible
    * `:exception` - adds tracing of the return value or raising of the call
    * `:return` - adds tracing of the return value of the call
    * `:stack` - adds a full stacktrace to the call trace events
    * `{:trace, [flag] | flag}` - adds the trace flags to the calling process
  when a function matching the `pattern` is called, equivalent to calling
  `Dbg.trace([flag])` in the calling process
    * `{:trace, pid, [flag] | flag}` - adds the trace flags to pid when a
  function matching the `pattern` is called, equivalent to calling
  `Dbg.trace(pid, [flag])`
    * `:clear` - clears all trace flags from the calling process when a function
  matching the `pattern` is called, equivalent to calling `Dbg.clear()` in the
  calling process
    * `{:clear, pid}` - clears all trace flags from the pid when a function
  matching the `pattern` is called, equivalent to calling `Dbg.clear(pid)`
    * `{:silent, boolean}` - turns on or off the `:silent` trace flag in the
  calling process when a function matching the `pattern` is called.

  `match_spec` must be a match spec that matches on a list (or a variable) and
  returns a list of `option`'s, or an empty list. Some complex match specs may
  not be allowed.

  A global function call is a call to an external module, i.e. a call that
  includes the module name. `Mod.function()` is a global call but `function()`
  is a local call. To trace both global and local calls use `Dbg.local_call/2`.

  For example:

      # Trace calls to all functions in Map
      Dbg.call(Map)

      # Trace calls to Map.new()
      Dbg.call({Map, new, 0})

      # Or equivalently:
      Dbg.call(&Map.new/0)

      # Include the stacktrace in trace events for the call  Map.new()
      Dbg.call(&Map.new/0, [:stack])

      # Trace the call and return of Enum.map/2 calls
      Dbg.call(&Enum.map/2, [:return])

      # Hide the call trace events of the calling process when GenServer.call/2
      # is called and reuse the pattern for GenServer.call/3
      %{saved: saved} = Dbg.call(&GenServer.call/2, [silent: true])
      Dbg.call(&GenServer.call/3, saved)

      # Turn on the :send flag in the process pid when Map.new() is called
      Dbg.call(&Map.new/0, {:trace, pid, [:send]}

      # Clear tracing flags in the calling process when Enum.map/2 is called
      # with a list as the first argument:
      Dbg.call(&Enum.map/2, [{[:"$1", :_], [{:is_list, :"$1"}], [:clear]}])
  """
  @spec call(fun_call) :: map
  @spec call(fun_call, pattern) :: map
  def call(target, pattern \\ nil) do
    try do
      apply_pattern(&:dbg.tp/2, target, pattern)
    else
      {:ok, result} ->
        parse_result(result)
      {:error, reason} ->
        exit({reason, {__MODULE__, :call, [target, pattern]}})
    catch
      :exit, :dbg_server_crash ->
        exit({:dbg_server_crash, {__MODULE__, :call, [target, pattern]}})
    end
  end

  @doc """
  Set call tracing for local (and global) function calls.

  The the same as `Dbg.call/2` except will trace all function calls.
  """
  @spec local_call(fun_call) :: map
  @spec local_call(fun_call, pattern) :: map
  def local_call(target, pattern \\ nil) do
    try do
      apply_pattern(&:dbg.tpl/2, target, pattern)
    else
      {:ok, result} ->
        parse_result(result)
      {:error, reason} ->
        exit({reason, {__MODULE__, :local_call, [target, pattern]}})
    catch
      :exit, :dbg_server_crash ->
        exit({:dbg_server_crash,
          {__MODULE__, :local_call, [target, pattern]}})
    end
  end

  @doc """
  Cancels all tracing for a `target` set by `Dbg.call/2` or `Dbg.local_call/2`.

  For example:

      # Cancel the tracing of all functions in Map
      Dbg.cancel(Map)

      # Cancel the tracing of Map.new() calls
      Dbg.cancel(&Map.new/0)
  """
  @spec cancel(fun_call) :: map
  def cancel(target) do
    try do
      apply_target(&:dbg.ctp/1, target)
    else
      {:ok, result} ->
        parse_result(result)
      {:error, reason} ->
        exit({reason, {__MODULE__, :cancel, [target]}})
    catch
      :exit, :dbg_server_crash ->
        exit({:dbg_server_crash, {__MODULE__, :cancel, [target]}})
    end
  end

  @doc """
  Returns all stored `pattern`'s for use with `Dbg.call/2` and
  `Dbg.local_call/2`.
  """
  @spec patterns() :: map
  def patterns() do
    case req(:get_table) do
      {:ok, {:ok, tid}} ->
        patterns(tid)
      {:error, reason} ->
        exit({reason, {__MODULE__, :patterns, []}})
    end
  end

  @doc """
  Reset `Dbg` to remove all tracing and create a new tracing process.
  """
  @spec reset() :: :ok
  def reset() do
    flush()
    Dbg.Watcher.reset()
  end

  @doc """
  Blocks while trace events are delivered and (when outputting to file) any
  data is flushed to disk.

  If the outputting to a `IO.device` does not guarantee that the trace
  events have been sent, only that they have been received by the tracer.
  """
  @spec flush() :: :ok
  def flush() do
    # Abuse code that (hopefully) exists on all nodes to ensure traces
    # delivered. This will fail on all nodes but only after checking traces
    # delivered
    nodes = Dbg.nodes()
    _ = :rpc.multicall(nodes, :dbg, :deliver_and_flush, [:undefined])
    # flush the local file trace port (if it exists).
    try do
      :dbg.flush_trace_port()
    else
      _ ->
        :ok
    catch
      :exit, _ ->
        :ok
    end
  end

  @doc """
  Prints (and formats) a binary trace file to the `IO.device`.

  For example:

      # Print trace events from "dbg.log" to :standard_io
      Dbg.inspect_file("dbg.log")
  """
  @spec inspect_file(Path.t) :: :ok | {:error, any}
  @spec inspect_file(IO.device, Path.t) :: :ok | {:error, any}
  def inspect_file(device \\ :standard_io, file) do
    erl_file = IO.chardata_to_string(file) |> String.to_char_list()
    # race condition here, pid could close before monitor.
    pid = :dbg.trace_client(:file, erl_file, Dbg.Handler.spec(device))
    ref = Process.monitor(pid)
    receive do
      {:DOWN, ^ref, _, _, :normal} ->
        :ok
      {:DOWN, ^ref, _, _, reason} ->
        {:error, reason}
    end
  end

  ## internal

  defp whereis(pid) when is_pid(pid), do: pid
  defp whereis(name) when is_atom(name), do: Process.whereis(name)

  defp whereis({ name, node_name })
      when is_atom(name) and node_name === node() do
    Process.whereis(name)
  end

  defp whereis({ :global, name }) do
    case :global.whereis_name(name) do
      :undefined ->
        nil
      pid ->
        pid
    end
  end

  defp whereis({ name, node_name }) when is_atom(name) and is_atom(node_name) do
    case :rpc.call(node_name, :erlang, :whereis, [name]) do
      pid when is_pid(pid) ->
        pid
      # :undefined or bad rpc
      _other ->
        nil
    end
  end

  defp whereis({ :via, mod, name }) when is_atom(name) do
    case mod.whereis_name(name) do
      :undefined ->
        nil
      pid ->
        pid
    end
  end

  defp req(request) do
    case Process.whereis(:dbg) do
      nil ->
        {:error, :noproc}
      pid ->
        req(pid, request)
    end
  end

  defp req(pid, request) do
    ref = Process.monitor(pid)
    send(pid, {self(), request})
    receive do
      {:DOWN, ^ref, _, _, _} ->
        # copy behaviour of other
        {:error, :dbg_server_crash}
      {:dbg, response} ->
        {:ok, response}
    end
  end

  defp ext_fun_info(ext_fun) do
    { :module, mod } = :erlang.fun_info(ext_fun, :module)
    { :name, name } = :erlang.fun_info(ext_fun, :name)
    { :arity, arity } = :erlang.fun_info(ext_fun, :arity)
    { mod, name, arity}
  end

  defp apply_pattern(fun, target, pattern) do
    fun.(get_target(target), get_pattern(pattern))
  end

  defp apply_target(fun, target) do
    fun.(get_target(target))
  end

  defp get_target({ _mod, _fun, _arity } = target), do: target
  defp get_target({ mod, fun }), do: { mod, fun, :_ }
  defp get_target(mod) when is_atom(mod), do: { mod, :_, :_ }

  defp get_target(ext_fun) when is_function(ext_fun) do
    case :erlang.fun_info(ext_fun, :type) do
      {:type, :external} ->
        ext_fun_info(ext_fun)
        _other ->
          raise ArgumentError, "#{inspect(ext_fun)} is not an external fun"
    end
  end

  defp get_pattern(id) when is_integer(id) or id in [:c, :x, :cx], do: id

  defp get_pattern(nil), do: get_pattern([])

  defp get_pattern(option) when is_atom(option) or is_tuple(option) do
    get_pattern([option])
  end

  defp get_pattern(options)
      when is_atom(hd(options)) or
        elem(hd(options), 0) in [ :silent, :trace, :clear] do
    Dbg.MatchSpec.transform([{:_, [], options}])
  end

  defp get_pattern(string) when is_binary(string) do
    {[match_spec], _ } = Dbg.MatchSpec.eval_string(string)
    match_spec
  end

  defp get_pattern(fun) when is_function(fun, 1) do
    Dbg.MatchSpec.eval_fun(fun)
  end

  defp get_pattern(match_spec) when is_list(match_spec) do
    Dbg.MatchSpec.transform(match_spec)
  end

  defp parse_result(result) do
    {id, good, bad} = Enum.reduce(result, {nil, %{}, %{}}, &parse_result/2)
    result = %{counts: good, errors: bad}
    if id === nil, do: result, else: Map.put(result, :saved, id)
  end

  defp parse_result({:matched, node_name, count}, {id, good, bad}) do
    {id, Map.put(good, node_name, count), bad}
  end

  defp parse_result({:matched, node_name, 0, error}, {id, good, bad}) do
    {id, good, Map.put(bad, node_name, error)}
  end

  defp parse_result({:saved, id}, {_id, good, bad}) do
    {id, good, bad}
  end

  defp patterns(tid) do
    ms = :ets.fun2ms(fn({id, bin}) when is_integer(id) or id in [:x, :c, :cx] ->
      {id, bin}
    end)
    :ets.select(tid, ms)
      |> Enum.reduce(%{}, &patterns/2)
  end

  defp patterns({id, binary}, map) do
    try do
      pattern = Dbg.MatchSpec.untransform(:erlang.binary_to_term(binary))
      Map.put(map, id, pattern)
    catch
      # failed to convert ms body (added using :dbg), ignore.
      :error, _ ->
        map
    end
  end

end
