defmodule Automaton.Runs.Run do
  use Ecto.Schema
  import Ecto.Changeset

  schema "runs" do
    field :status, :string, default: "pending"
    field :trigger_type, :string
    field :input, :map, default: %{}
    field :state, :map, default: %{}
    field :agent_version, :integer
    field :policy_version, :integer
    field :prompt_bundle_version, :integer
    field :model_config_version, :string
    field :tooling_config_version, :string

    belongs_to :agent, Automaton.Runs.Agent
    has_many :events, Automaton.Runs.RunEvent
    has_many :decisions, Automaton.Runs.RunDecision

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :agent_id,
      :status,
      :trigger_type,
      :input,
      :state,
      :agent_version,
      :policy_version,
      :prompt_bundle_version,
      :model_config_version,
      :tooling_config_version
    ])
    |> validate_required([:agent_id, :status, :trigger_type, :agent_version])
    |> validate_inclusion(:status, ["pending", "running", "awaiting_input", "blocked", "escalated", "completed", "failed"])
    |> foreign_key_constraint(:agent_id)
  end
end
