defmodule Norns.Repo.Migrations.CreateTriggers do
  use Ecto.Migration

  def change do
    create table(:triggers) do
      add :tenant_id, references(:tenants), null: false
      add :agent_id, references(:agents), null: false
      add :name, :string, null: false
      add :cron, :string, null: false
      add :message, :text, null: false
      add :conversation_key, :string
      add :enabled, :boolean, default: true, null: false
      add :last_fired_at, :utc_datetime_usec

      timestamps()
    end

    create index(:triggers, [:tenant_id])
    create index(:triggers, [:tenant_id, :agent_id])
    create unique_index(:triggers, [:tenant_id, :name])
    create index(:triggers, [:enabled])
  end
end
