defmodule SymphonyElixir.TransitionJournal do
  @moduledoc """
  Synchronous, replayable transition write-ahead log backed by OTP `:disk_log`.

  A journal process owns one workflow log. Each phase write is flushed before
  the call returns, so the orchestrator can safely perform the corresponding
  external effect afterwards.
  """

  use GenServer

  @phases [
    :received,
    :decided,
    :required_comment_applied,
    :review_threads_applied,
    :projection_applied,
    :verified,
    :retrying
  ]

  defmodule Event do
    @moduledoc "A durable transition phase record."

    @enforce_keys [:version, :transition_id, :phase, :data, :recorded_at]
    defstruct [:version, :transition_id, :phase, :data, :recorded_at]

    @type t :: %__MODULE__{
            version: pos_integer(),
            transition_id: String.t(),
            phase: SymphonyElixir.TransitionJournal.phase(),
            data: map(),
            recorded_at: integer()
          }
  end

  defmodule Snapshot do
    @moduledoc "Latest replayed state for one transition."

    @enforce_keys [:transition_id, :phase, :data, :history]
    defstruct [:transition_id, :phase, :data, :history]

    @type t :: %__MODULE__{
            transition_id: String.t(),
            phase: SymphonyElixir.TransitionJournal.phase(),
            data: map(),
            history: [SymphonyElixir.TransitionJournal.Event.t()]
          }
  end

  defmodule State do
    @moduledoc false
    defstruct [:path, :log_name, :lock_name, :lock_path, snapshots: %{}, events: []]
  end

  @type phase ::
          :received
          | :decided
          | :required_comment_applied
          | :review_threads_applied
          | :projection_applied
          | :verified
          | :retrying

  @type record_result :: {:ok, Event.t()} | {:noop, atom()} | {:error, term()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    with {:ok, path} <- fetch_path(opts),
         :ok <- ensure_available(path) do
      case Keyword.get(opts, :name) do
        nil -> GenServer.start_link(__MODULE__, Keyword.put(opts, :path, path))
        name -> GenServer.start_link(__MODULE__, Keyword.put(opts, :path, path), name: name)
      end
    end
  end

  @spec phases() :: [phase()]
  def phases, do: @phases

  @spec record(GenServer.server(), String.t(), phase(), map()) :: record_result()
  def record(journal, transition_id, phase, data \\ %{}) do
    GenServer.call(journal, {:record, transition_id, phase, data})
  end

  @spec replay(GenServer.server()) :: [Event.t()]
  def replay(journal), do: GenServer.call(journal, :replay)

  @spec snapshot(GenServer.server(), String.t()) :: {:ok, Snapshot.t()} | :error
  def snapshot(journal, transition_id), do: GenServer.call(journal, {:snapshot, transition_id})

  @spec pending(GenServer.server()) :: [Snapshot.t()]
  def pending(journal), do: GenServer.call(journal, :pending)

  @spec close(GenServer.server()) :: :ok
  def close(journal), do: GenServer.stop(journal, :normal)

  @impl true
  def init(opts) do
    with {:ok, path} <- fetch_path(opts),
         :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, lock_name, lock_path} <- acquire_lock(path),
         log_name = Keyword.get(opts, :log_name, log_name(path)),
         {:ok, events} <- open_and_read_events(log_name, path, lock_name, lock_path) do
      {:ok,
       %State{
         path: path,
         log_name: log_name,
         lock_name: lock_name,
         lock_path: lock_path,
         events: events,
         snapshots: build_snapshots(events)
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:record, transition_id, phase, data}, _from, %State{} = state) do
    case validate_record(state, transition_id, phase, data) do
      :ok -> write_event(state, transition_id, phase, data)
      {:noop, reason} -> {:reply, {:noop, reason}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:replay, _from, %State{} = state) do
    {:reply, state.events, state}
  end

  def handle_call({:snapshot, transition_id}, _from, %State{} = state) do
    {:reply, Map.fetch(state.snapshots, transition_id), state}
  end

  def handle_call(:pending, _from, %State{} = state) do
    pending = state.snapshots |> Map.values() |> Enum.reject(&(&1.phase == :verified)) |> Enum.sort_by(& &1.transition_id)
    {:reply, pending, state}
  end

  @impl true
  def terminate(_reason, %State{} = state) do
    _ = :disk_log.close(state.log_name)
    :global.unregister_name(state.lock_name)
    _ = File.rm(state.lock_path)
    :ok
  end

  defp fetch_path(opts) do
    case Keyword.fetch(opts, :path) do
      {:ok, path} when is_binary(path) and path != "" -> {:ok, Path.expand(path)}
      _ -> {:error, :missing_journal_path}
    end
  end

  defp acquire_lock(path) do
    lock_name = {__MODULE__, path}

    case :global.register_name(lock_name, self()) do
      :yes -> acquire_file_lock(path, lock_name)
      :no -> {:error, {:journal_already_open, path}}
    end
  end

  defp acquire_file_lock(path, lock_name) do
    lock_path = path <> ".lock"

    case File.open(lock_path, [:write, :exclusive]) do
      {:ok, io} ->
        IO.binwrite(io, System.pid())
        File.close(io)
        {:ok, lock_name, lock_path}

      {:error, :eexist} ->
        recover_stale_file_lock(path, lock_name, lock_path)

      {:error, reason} ->
        :global.unregister_name(lock_name)
        {:error, {:journal_lock_failed, reason}}
    end
  end

  defp recover_stale_file_lock(path, lock_name, lock_path) do
    with {:ok, owner_pid} <- File.read(lock_path),
         true <- stale_lock_owner?(String.trim(owner_pid)),
         :ok <- File.rm(lock_path) do
      acquire_file_lock(path, lock_name)
    else
      _ ->
        :global.unregister_name(lock_name)
        {:error, {:journal_already_open, path}}
    end
  end

  defp stale_lock_owner?(owner_pid), do: owner_pid == System.pid() or not os_process_alive?(owner_pid)

  defp os_process_alive?(pid) do
    case Regex.match?(~r/^\d+$/, pid) do
      true ->
        case System.cmd("kill", ["-0", pid], stderr_to_stdout: true) do
          {_output, 0} -> true
          _ -> false
        end

      false ->
        false
    end
  end

  defp ensure_available(path) do
    case :global.whereis_name({__MODULE__, path}) do
      :undefined -> :ok
      _pid -> {:error, {:journal_already_open, path}}
    end
  end

  defp log_name(path) do
    digest = :crypto.hash(:sha256, path) |> Base.encode16(case: :lower)
    String.to_atom("symphony_transition_journal_#{digest}")
  end

  defp open_log(log_name, path) do
    options = [name: log_name, file: String.to_charlist(path), type: :halt, format: :internal, repair: true]

    case :disk_log.open(options) do
      {:ok, ^log_name} -> {:ok, log_name}
      {:repaired, ^log_name, _recovered, _bad_bytes} -> {:ok, log_name}
      {:error, reason} -> release_failed_open(path, reason)
    end
  end

  defp open_and_read_events(log_name, path, lock_name, lock_path) do
    with {:ok, ^log_name} <- open_log(log_name, path) do
      case read_events(log_name) do
        {:ok, events} ->
          {:ok, events}

        {:error, reason} ->
          _ = :disk_log.close(log_name)
          :global.unregister_name(lock_name)
          _ = File.rm(lock_path)
          {:error, reason}
      end
    end
  end

  defp release_failed_open(path, reason) do
    :global.unregister_name({__MODULE__, path})
    _ = File.rm(path <> ".lock")
    {:error, {:journal_open_failed, reason}}
  end

  defp read_events(log_name), do: read_chunks(log_name, :start, [])

  defp read_chunks(log_name, continuation, acc) do
    case :disk_log.chunk(log_name, continuation) do
      :eof -> {:ok, Enum.reverse(acc)}
      {next, events} when is_list(events) -> read_chunks(log_name, next, Enum.reverse(events, acc))
      {next, events, _bad_bytes} when is_list(events) -> read_chunks(log_name, next, Enum.reverse(events, acc))
      {:error, reason} -> {:error, {:journal_replay_failed, reason}}
    end
  end

  defp build_snapshots(events) do
    Enum.reduce(events, %{}, fn
      %Event{} = event, snapshots -> update_snapshot(snapshots, event)
      _invalid_event, snapshots -> snapshots
    end)
  end

  defp validate_record(_state, transition_id, _phase, _data) when not is_binary(transition_id) or transition_id == "", do: {:error, :invalid_transition_id}
  defp validate_record(_state, _transition_id, phase, _data) when phase not in @phases, do: {:error, {:invalid_phase, phase}}
  defp validate_record(_state, _transition_id, _phase, data) when not is_map(data), do: {:error, :invalid_event_data}

  defp validate_record(%State{} = state, transition_id, phase, _data) do
    current_phase = state.snapshots |> Map.get(transition_id) |> current_phase()

    cond do
      current_phase == phase -> {:noop, :phase_already_recorded}
      current_phase == :verified -> {:noop, :already_verified}
      valid_phase_step?(current_phase, phase) -> :ok
      true -> {:error, {:invalid_phase_transition, current_phase, phase}}
    end
  end

  defp current_phase(nil), do: nil
  defp current_phase(%Snapshot{phase: phase}), do: phase

  defp valid_phase_step?(nil, :received), do: true
  defp valid_phase_step?(:received, phase) when phase in [:decided, :retrying], do: true

  defp valid_phase_step?(:decided, phase)
       when phase in [:required_comment_applied, :review_threads_applied, :projection_applied, :verified, :retrying],
       do: true

  defp valid_phase_step?(:required_comment_applied, phase) when phase in [:review_threads_applied, :projection_applied, :retrying], do: true
  defp valid_phase_step?(:review_threads_applied, phase) when phase in [:projection_applied, :retrying], do: true
  defp valid_phase_step?(:projection_applied, phase) when phase in [:verified, :retrying], do: true
  defp valid_phase_step?(:retrying, phase) when phase in [:decided, :required_comment_applied, :review_threads_applied, :projection_applied, :verified], do: true
  defp valid_phase_step?(_current, _next), do: false

  defp write_event(%State{} = state, transition_id, phase, data) do
    event = %Event{
      version: 1,
      transition_id: transition_id,
      phase: phase,
      data: data,
      recorded_at: System.system_time(:millisecond)
    }

    with :ok <- :disk_log.log(state.log_name, event),
         :ok <- :disk_log.sync(state.log_name) do
      new_state = %{
        state
        | events: state.events ++ [event],
          snapshots: update_snapshot(state.snapshots, event)
      }

      {:reply, {:ok, event}, new_state}
    else
      {:error, reason} -> {:reply, {:error, {:journal_write_failed, reason}}, state}
    end
  end

  defp update_snapshot(snapshots, %Event{} = event) do
    previous = Map.get(snapshots, event.transition_id)

    snapshot = %Snapshot{
      transition_id: event.transition_id,
      phase: event.phase,
      data: Map.merge(if(previous, do: previous.data, else: %{}), event.data),
      history: if(previous, do: previous.history ++ [event], else: [event])
    }

    Map.put(snapshots, event.transition_id, snapshot)
  end
end
