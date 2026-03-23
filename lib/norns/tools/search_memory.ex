defmodule Norns.Tools.SearchMemory do
  @moduledoc "Search persistent memories for the current agent."

  use Norns.Tools.Behaviour

  alias Norns.Memories

  @max_results 10

  @impl true
  def name, do: "search_memory"

  @impl true
  def description do
    "Search shared agent memory by keyword across memory keys and content."
  end

  @impl true
  def input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "query" => %{"type" => "string", "description" => "The keyword query to search"}
      },
      "required" => ["query"]
    }
  end

  @impl true
  def execute(%{"query" => query}) do
    with {:ok, %{agent_id: agent_id}} <- tool_context() do
      memories = Memories.search_memories(agent_id, query) |> Enum.take(@max_results)

      if memories == [] do
        {:ok, "No memories found for '#{query}'."}
      else
        formatted =
          memories
          |> Enum.with_index(1)
          |> Enum.map_join("\n", fn {memory, index} ->
            "#{index}. #{memory.key}: #{memory.content}"
          end)

        {:ok, "Found #{length(memories)} memories for '#{query}':\n#{formatted}"}
      end
    end
  end

  def execute(_input), do: {:error, "Missing required parameter: query"}

  defp tool_context do
    case Process.get(:norns_tool_context) do
      %{agent_id: _agent_id} = context -> {:ok, context}
      _ -> {:error, "Tool context unavailable"}
    end
  end
end
