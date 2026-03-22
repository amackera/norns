defmodule Norns.Repo.Migrations.RemoveUnusedRunFields do
  use Ecto.Migration

  def change do
    alter table(:runs) do
      remove :state, :map, default: %{}
      remove :resumed_from_event_id, :integer
    end
  end
end
