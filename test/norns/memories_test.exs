defmodule Norns.MemoriesTest do
  use Norns.DataCase, async: true

  alias Norns.Memories

  test "memory CRUD and keyword search" do
    tenant = create_tenant()
    agent = create_agent(tenant)

    {:ok, memory} =
      Memories.create_memory(%{
        agent_id: agent.id,
        tenant_id: tenant.id,
        key: "dark-mode-launch",
        content: "Dark mode shipped to all users.",
        metadata: %{"source" => "release"}
      })

    assert memory.metadata["source"] == "release"

    {:ok, updated} =
      Memories.update_memory(memory, %{
        content: "Dark mode shipped on Tuesday."
      })

    assert updated.content =~ "Tuesday"

    {:ok, upserted} =
      Memories.upsert_memory(%{
        agent_id: agent.id,
        tenant_id: tenant.id,
        key: "dark-mode-launch",
        content: "Dark mode shipped broadly."
      })

    assert upserted.id == memory.id

    {:ok, _other} =
      Memories.create_memory(%{
        agent_id: agent.id,
        tenant_id: tenant.id,
        key: "pricing-api",
        content: "The pricing API returns currency-aware amounts."
      })

    assert [%{key: "dark-mode-launch"}] = Memories.search_memories(agent.id, "dark")
    assert [%{key: "pricing-api"}] = Memories.search_memories(agent.id, "currency")
    assert length(Memories.list_memories(agent.id)) == 2

    assert {:ok, _deleted} = Memories.delete_memory(upserted)
    assert Memories.get_memory(memory.id) == nil
  end
end
