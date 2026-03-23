defmodule Norns.ConversationsTest do
  use Norns.DataCase, async: true

  alias Norns.Conversations

  test "conversation CRUD and find_or_create helpers" do
    tenant = create_tenant()
    agent = create_agent(tenant)

    {:ok, conversation} =
      Conversations.create_conversation(%{
        agent_id: agent.id,
        tenant_id: tenant.id,
        key: "slack:C123",
        messages: [%{role: "user", content: "hello"}]
      })

    assert conversation.message_count == 1
    assert Conversations.get_conversation_by_agent_key!(agent.id, "slack:C123").id == conversation.id

    {:ok, same_conversation} =
      Conversations.find_or_create_conversation(agent.id, tenant.id, "slack:C123")

    assert same_conversation.id == conversation.id

    {:ok, updated} =
      Conversations.update_conversation(conversation, %{
        messages: [
          %{role: "user", content: "hello"},
          %{role: "assistant", content: [%{"type" => "text", "text" => "hi"}]}
        ]
      })

    assert updated.message_count == 2
    assert updated.token_estimate > 0

    assert [listed] = Conversations.list_conversations(agent.id)
    assert listed.id == updated.id

    assert {:ok, _deleted} = Conversations.delete_conversation(updated)
    assert Conversations.get_conversation(updated.id) == nil
  end
end
