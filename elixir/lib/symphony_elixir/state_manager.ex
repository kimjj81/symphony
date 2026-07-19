defmodule SymphonyElixir.StateManager do
  @moduledoc """
  Public request boundary for the orchestrator-owned workflow state manager.

  The orchestrator remains the process that serializes requests. This module
  only defines the stable call shape and result contract.
  """

  alias SymphonyElixir.{AppliedTransition, TransitionIntent}

  @type result ::
          {:ok, AppliedTransition.t()}
          | {:noop, term()}
          | {:conflict, map()}
          | {:rejected, term()}
          | {:error, term()}

  @spec request(TransitionIntent.t()) :: result()
  def request(%TransitionIntent{} = intent) do
    request(SymphonyElixir.Orchestrator, intent)
  end

  @spec request(GenServer.server(), TransitionIntent.t()) :: result()
  def request(server, %TransitionIntent{} = intent) do
    GenServer.call(server, {:transition_request, intent}, :infinity)
  end
end
