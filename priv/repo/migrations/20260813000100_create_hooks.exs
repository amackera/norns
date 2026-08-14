defmodule Norns.Repo.Migrations.CreateHooks do
  use Ecto.Migration

  def change do
    create table(:hooks) do
      add :tenant_id, references(:tenants), null: false
      add :agent_id, references(:agents), null: false
      add :name, :string, null: false
      add :token, :string, null: false
      add :message_path, :string
      add :conversation_key_path, :string
      add :signature_type, :string, null: false, default: "none"
      add :signing_secret, :string
      add :enabled, :boolean, default: true, null: false

      timestamps()
    end

    create unique_index(:hooks, [:token])
    create unique_index(:hooks, [:tenant_id, :name])
    create index(:hooks, [:tenant_id])
  end
end
