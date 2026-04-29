defmodule SymphonyElixir.Linear.Issue do
  @moduledoc """
  Compatibility helpers for the former Linear-specific issue module.
  """

  alias SymphonyElixir.Tracker.Issue

  @type t :: Issue.t()

  @spec label_names(t()) :: [String.t()]
  def label_names(%Issue{labels: labels}) do
    labels
  end
end
