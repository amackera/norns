defmodule Automaton.Runs.RunDecision do
  use Ecto.Schema
  import Ecto.Changeset

  schema "run_decisions" do
    field :decision_point, :string
    field :decision, :string
    field :reason_codes, {:array, :string}, default: []
    field :details, :map, default: %{}

    belongs_to :run, Automaton.Runs.Run
    belongs_to :run_event, Automaton.Runs.RunEvent

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(decision, attrs) do
    decision
    |> cast(attrs, [:run_id, :run_event_id, :decision_point, :decision, :reason_codes, :details])
    |> validate_required([:run_id, :decision_point, :decision])
    |> validate_inclusion(:decision, ["allow", "block", "escalate", "review"])
    |> foreign_key_constraint(:run_id)
    |> foreign_key_constraint(:run_event_id)
  end
end
