defmodule Automaton.Runs do
  @moduledoc """
  Core context for durable workflow runs.

  Provides basic primitives for starting runs, appending ordered events,
  recording gate decisions, and inspecting run timelines.
  """

  import Ecto.Query

  alias Automaton.Repo
  alias Automaton.Runs.{Run, RunEvent, RunDecision}

  def get_run(id), do: Repo.get(Run, id)
  def get_run!(id), do: Repo.get!(Run, id)

  def create_run(attrs) do
    %Run{}
    |> Run.changeset(attrs)
    |> Repo.insert()
  end

  def update_run(%Run{} = run, attrs) do
    run
    |> Run.changeset(attrs)
    |> Repo.update()
  end

  def append_event(%Run{} = run, attrs) do
    Repo.transaction(fn ->
      sequence = next_sequence(run.id)

      params =
        attrs
        |> Map.new()
        |> Map.put(:run_id, run.id)
        |> Map.put(:sequence, sequence)

      case %RunEvent{} |> RunEvent.changeset(params) |> Repo.insert() do
        {:ok, event} -> event
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  def record_decision(%Run{} = run, attrs) do
    params = attrs |> Map.new() |> Map.put(:run_id, run.id)

    %RunDecision{}
    |> RunDecision.changeset(params)
    |> Repo.insert()
  end

  def list_events(run_id) do
    RunEvent
    |> where([e], e.run_id == ^run_id)
    |> order_by([e], asc: e.sequence)
    |> Repo.all()
  end

  def list_decisions(run_id) do
    RunDecision
    |> where([d], d.run_id == ^run_id)
    |> order_by([d], asc: d.inserted_at)
    |> Repo.all()
  end

  def timeline(run_id) do
    events = list_events(run_id)

    decisions_by_event =
      RunDecision
      |> where([d], d.run_id == ^run_id)
      |> Repo.all()
      |> Enum.group_by(& &1.run_event_id)

    Enum.map(events, fn event ->
      %{event: event, decisions: Map.get(decisions_by_event, event.id, [])}
    end)
  end

  defp next_sequence(run_id) do
    RunEvent
    |> where([e], e.run_id == ^run_id)
    |> select([e], max(e.sequence))
    |> Repo.one()
    |> case do
      nil -> 1
      n -> n + 1
    end
  end
end
