defmodule Norns.Repo.Migrations.AddFailureMetadataToRuns do
  use Ecto.Migration

  def change do
    alter table(:runs) do
      add :failure_metadata, :map, null: false, default: %{}
    end
  end
end
