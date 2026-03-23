defmodule Norns.Memories.Memory do
  use Ecto.Schema
  import Ecto.Changeset

  schema "memories" do
    field :key, :string
    field :content, :string
    field :metadata, :map, default: %{}

    belongs_to :agent, Norns.Agents.Agent
    belongs_to :tenant, Norns.Tenants.Tenant

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(memory, attrs) do
    memory
    |> cast(attrs, [:agent_id, :tenant_id, :key, :content, :metadata])
    |> validate_required([:agent_id, :tenant_id, :key, :content])
    |> foreign_key_constraint(:agent_id)
    |> foreign_key_constraint(:tenant_id)
    |> unique_constraint([:agent_id, :key])
  end
end
