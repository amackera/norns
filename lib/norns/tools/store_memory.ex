defmodule Norns.Tools.StoreMemory do
  @moduledoc "Store a persistent memory for the current agent."

  use Norns.Tools.Behaviour

  alias Norns.Memories

  @impl true
  def name, do: "store_memory"

  @impl true
  def description do
    "Remember an important fact, decision, or event so it is available across conversations."
  end

  @impl true
  def side_effect?, do: true

  @impl true
  def input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "key" => %{"type" => "string", "description" => "Short identifier for the memory"},
        "content" => %{"type" => "string", "description" => "The fact or detail to remember"},
        "metadata" => %{"type" => "object", "description" => "Optional tags or source details"}
      },
      "required" => ["key", "content"]
    }
  end

  @impl true
  def execute(%{"key" => key, "content" => content} = input) do
    with {:ok, %{agent_id: agent_id, tenant_id: tenant_id}} <- tool_context() do
      attrs = %{
        agent_id: agent_id,
        tenant_id: tenant_id,
        key: key,
        content: content,
        metadata: Map.get(input, "metadata", %{})
      }

      case Memories.upsert_memory(attrs) do
        {:ok, _memory} -> {:ok, "Stored memory: #{key}"}
        {:error, changeset} -> {:error, format_error(changeset)}
      end
    end
  end

  def execute(_input), do: {:error, "Missing required parameters: key, content"}

  defp tool_context do
    case Process.get(:norns_tool_context) do
      %{agent_id: _agent_id, tenant_id: _tenant_id} = context -> {:ok, context}
      _ -> {:error, "Tool context unavailable"}
    end
  end

  defp format_error(changeset) do
    "Could not store memory: " <>
      Enum.map_join(changeset.errors, ", ", fn {field, {message, _opts}} ->
        "#{field} #{message}"
      end)
  end
end
