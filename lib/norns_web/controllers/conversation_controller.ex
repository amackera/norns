defmodule NornsWeb.ConversationController do
  use NornsWeb, :controller

  alias Norns.{Agents, Conversations}

  def index(conn, %{"agent_id" => agent_id}) do
    tenant = conn.assigns.current_tenant

    with {:ok, agent} <- fetch_agent(agent_id, tenant.id) do
      conversations = Conversations.list_conversations(agent.id)
      json(conn, %{data: Enum.map(conversations, &NornsWeb.JSON.conversation/1)})
    end
  end

  def show(conn, %{"agent_id" => agent_id, "key" => key}) do
    tenant = conn.assigns.current_tenant

    with {:ok, agent} <- fetch_agent(agent_id, tenant.id),
         %{} = conversation <- Conversations.get_conversation_by_agent_key(agent.id, key) do
      json(conn, %{data: NornsWeb.JSON.conversation(conversation)})
    else
      nil -> conn |> put_status(404) |> json(%{error: "not found"})
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "not found"})
    end
  end

  def delete(conn, %{"agent_id" => agent_id, "key" => key}) do
    tenant = conn.assigns.current_tenant

    with {:ok, agent} <- fetch_agent(agent_id, tenant.id),
         %{} = conversation <- Conversations.get_conversation_by_agent_key(agent.id, key),
         {:ok, _conversation} <- Conversations.delete_conversation(conversation) do
      json(conn, %{status: "deleted"})
    else
      nil -> conn |> put_status(404) |> json(%{error: "not found"})
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "not found"})
    end
  end

  defp fetch_agent(id, tenant_id) do
    agent = Agents.get_agent!(id)

    if agent.tenant_id == tenant_id do
      {:ok, agent}
    else
      {:error, :not_found}
    end
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
  end
end
