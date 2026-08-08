defmodule Norns.Repo.Migrations.AddRunLineage do
  use Ecto.Migration

  def change do
    alter table(:runs) do
      # Nullable: a run started by a user has no parent.
      add :parent_run_id, references(:runs, on_delete: :nilify_all)
      # Absolute nesting level from the root run. Existing runs are roots.
      add :depth, :integer, null: false, default: 0
    end

    create index(:runs, [:parent_run_id])
  end
end
