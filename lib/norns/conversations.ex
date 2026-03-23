defmodule Norns.Conversations do
  @moduledoc "Conversation persistence and lookup."

  import Ecto.Query

  alias Norns.Conversations.Conversation
  alias Norns.Repo

  def list_conversations(agent_id) do
    Conversation
    |> where([c], c.agent_id == ^agent_id)
    |> order_by([c], desc: c.updated_at)
    |> Repo.all()
  end

  def get_conversation(id), do: Repo.get(Conversation, id)
  def get_conversation!(id), do: Repo.get!(Conversation, id)

  def get_conversation_by_agent_key(agent_id, key) do
    Conversation
    |> where([c], c.agent_id == ^agent_id and c.key == ^key)
    |> Repo.one()
  end

  def get_conversation_by_agent_key!(agent_id, key) do
    Conversation
    |> where([c], c.agent_id == ^agent_id and c.key == ^key)
    |> Repo.one!()
  end

  def create_conversation(attrs) do
    attrs = with_message_metrics(attrs)

    %Conversation{}
    |> Conversation.changeset(attrs)
    |> Repo.insert()
  end

  def update_conversation(%Conversation{} = conversation, attrs) do
    attrs = with_message_metrics(attrs)

    conversation
    |> Conversation.changeset(attrs)
    |> Repo.update()
  end

  def delete_conversation(%Conversation{} = conversation) do
    Repo.delete(conversation)
  end

  def find_or_create_conversation(agent_id, tenant_id, key, attrs \\ %{}) do
    case get_conversation_by_agent_key(agent_id, key) do
      %Conversation{} = conversation ->
        {:ok, conversation}

      nil ->
        attrs =
          attrs
          |> Map.new()
          |> Map.put(:agent_id, agent_id)
          |> Map.put(:tenant_id, tenant_id)
          |> Map.put(:key, key)

        create_conversation(attrs)
    end
  end

  defp with_message_metrics(attrs) do
    attrs = Map.new(attrs)

    case Map.fetch(attrs, :messages) do
      {:ok, messages} when is_list(messages) ->
        attrs
        |> Map.put_new(:message_count, length(messages))
        |> Map.put_new(:token_estimate, estimate_tokens(messages))

      _ ->
        attrs
    end
  end

  defp estimate_tokens(messages) do
    messages
    |> Enum.map(&message_size/1)
    |> Enum.sum()
    |> Kernel.div(4)
  end

  defp message_size(%{content: content}), do: encoded_size(content)
  defp message_size(%{"content" => content}), do: encoded_size(content)
  defp message_size(_message), do: 0

  defp encoded_size(content) do
    content
    |> Jason.encode!()
    |> byte_size()
  end
end
