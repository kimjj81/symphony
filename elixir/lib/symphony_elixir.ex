defmodule SymphonyElixir do
  @moduledoc """
  Entry point for the Symphony orchestrator.
  """

  @doc """
  Start the orchestrator in the current BEAM node.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    SymphonyElixir.Orchestrator.start_link(opts)
  end
end

defmodule SymphonyElixir.Application do
  @moduledoc """
  OTP application entrypoint that starts core supervisors and workers.
  """

  use Application

  alias SymphonyElixir.{Config, TransitionJournal}
  alias SymphonyElixir.GitHub.NatsWebhookConsumer

  @impl true
  def start(_type, _args) do
    :ok = SymphonyElixir.LogFile.configure()

    journal_children =
      case Config.settings() do
        {:ok, %{state_manager: %{mode: mode}}} when mode in ["shadow", "authoritative"] ->
          [{TransitionJournal, name: TransitionJournal, path: Config.transition_journal_path()}]

        _ ->
          []
      end

    children =
      [
        {Phoenix.PubSub, name: SymphonyElixir.PubSub},
        {Task.Supervisor, name: SymphonyElixir.TaskSupervisor},
        SymphonyElixir.WorkflowStore
      ] ++
        journal_children ++
        [
          SymphonyElixir.Orchestrator,
          SymphonyElixir.HttpServer,
          SymphonyElixir.StatusDashboard
        ] ++ NatsWebhookConsumer.child_specs_from_env()

    Supervisor.start_link(
      children,
      strategy: :one_for_one,
      name: SymphonyElixir.Supervisor
    )
  end

  @impl true
  def stop(_state) do
    SymphonyElixir.StatusDashboard.render_offline_status()
    :ok
  end
end
