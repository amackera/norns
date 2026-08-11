defmodule Norns.Triggers.Trigger do
  @moduledoc """
  A cron schedule that starts a run on an agent.

  Triggers are Norns data, not worker config — a composed agent has no repo
  for a schedule to live in (see `docs/plan-agent-builder.md`). The `cron`
  field is a standard five-field expression (or an `@daily`-style alias),
  validated with `Oban.Cron.Expression`. `message` is the content the run
  starts with, as if a user had sent it.

  `conversation_key` is optional: unset, every firing starts a fresh
  conversation (task mode); set, firings share persistent history under that
  key. `last_fired_at` is the dedupe claim — a trigger fires at most once per
  matching minute, no matter how many schedulers observe it.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "triggers" do
    field :name, :string
    field :cron, :string
    field :message, :string
    field :conversation_key, :string
    field :enabled, :boolean, default: true
    field :last_fired_at, :utc_datetime_usec

    belongs_to :tenant, Norns.Tenants.Tenant
    belongs_to :agent, Norns.Agents.Agent

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(trigger, attrs) do
    trigger
    |> cast(attrs, [:tenant_id, :agent_id, :name, :cron, :message, :conversation_key, :enabled])
    |> validate_required([:tenant_id, :agent_id, :name, :cron, :message])
    |> validate_cron()
    |> unique_constraint([:tenant_id, :name])
    |> foreign_key_constraint(:agent_id)
  end

  defp validate_cron(changeset) do
    validate_change(changeset, :cron, fn :cron, cron ->
      case Oban.Cron.Expression.parse(cron) do
        {:ok, _} -> []
        {:error, %{message: message}} -> [cron: message]
        {:error, _} -> [cron: "is not a valid cron expression"]
      end
    end)
  rescue
    _ -> add_error(changeset, :cron, "is not a valid cron expression")
  end
end
