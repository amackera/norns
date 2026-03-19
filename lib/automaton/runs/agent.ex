defmodule Automaton.Runs.Agent do
  use Ecto.Schema
  import Ecto.Changeset

  schema "agents" do
    field :name, :string
    field :purpose, :string
    field :status, :string, default: "inactive"
    field :current_agent_version, :integer, default: 1
    field :metadata, :map, default: %{}

    has_many :runs, Automaton.Runs.Run

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(agent, attrs) do
    agent
    |> cast(attrs, [:name, :purpose, :status, :current_agent_version, :metadata])
    |> validate_required([:name, :status, :current_agent_version])
    |> validate_inclusion(:status, ["inactive", "idle", "running"])
    |> unique_constraint(:name)
  end
end
