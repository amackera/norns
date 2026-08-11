defmodule Norns.Repo.Migrations.CreateGards do
  use Ecto.Migration

  def change do
    create table(:gards) do
      add :tenant_id, references(:tenants), null: false
      add :name, :string
      add :status, :string, null: false, default: "pending"
      add :template, :string
      add :claim_token, :string, null: false
      add :metadata, :map, default: %{}, null: false

      timestamps()
    end

    create index(:gards, [:tenant_id])
    create index(:gards, [:tenant_id, :status])

    create table(:gard_ports) do
      add :gard_id, references(:gards, on_delete: :delete_all), null: false
      add :internal_port, :integer, null: false
      add :url, :string
      add :name, :string
      add :protocol, :string, default: "http", null: false

      timestamps()
    end

    create index(:gard_ports, [:gard_id])

    alter table(:runs) do
      add :gard_id, references(:gards), null: true
    end
  end
end
