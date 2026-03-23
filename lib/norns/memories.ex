defmodule Norns.Memories do
  @moduledoc "Cross-conversation memory persistence and search."

  import Ecto.Query

  alias Norns.Memories.Memory
  alias Norns.Repo

  def list_memories(agent_id) do
    Memory
    |> where([m], m.agent_id == ^agent_id)
    |> order_by([m], asc: m.key)
    |> Repo.all()
  end

  def get_memory(id), do: Repo.get(Memory, id)
  def get_memory!(id), do: Repo.get!(Memory, id)

  def get_memory_by_agent_key(agent_id, key) do
    Memory
    |> where([m], m.agent_id == ^agent_id and m.key == ^key)
    |> Repo.one()
  end

  def create_memory(attrs) do
    %Memory{}
    |> Memory.changeset(attrs)
    |> Repo.insert()
  end

  def update_memory(%Memory{} = memory, attrs) do
    memory
    |> Memory.changeset(attrs)
    |> Repo.update()
  end

  def upsert_memory(attrs) do
    attrs = Map.new(attrs)

    case get_memory_by_agent_key(attrs[:agent_id], attrs[:key]) do
      %Memory{} = memory -> update_memory(memory, attrs)
      nil -> create_memory(attrs)
    end
  end

  def delete_memory(%Memory{} = memory) do
    Repo.delete(memory)
  end

  def search_memories(agent_id, query) do
    pattern = "%" <> query <> "%"

    Memory
    |> where([m], m.agent_id == ^agent_id)
    |> where([m], ilike(m.key, ^pattern) or ilike(m.content, ^pattern))
    |> order_by([m], asc: m.key)
    |> Repo.all()
  end
end
