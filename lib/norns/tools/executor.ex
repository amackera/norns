defmodule Norns.Tools.Executor do
  @moduledoc "Matches tool_use blocks to registered tools and executes them."

  alias Norns.Tools.Tool
  alias Norns.Workers.WorkerRegistry

  @doc """
  Execute a tool call. Finds the matching tool by name and calls its handler.
  Supports both local and remote (worker-provided) tools.
  """
  def execute(%{"name" => name, "input" => input}, tools) when is_list(tools) do
    case Enum.find(tools, &(&1.name == name)) do
      %Tool{source: {:remote, tenant_id}} ->
        execute_remote(tenant_id, name, input)

      %Tool{handler: handler} ->
        try do
          handler.(input)
        rescue
          e -> {:error, "Tool execution error: #{Exception.message(e)}"}
        end

      nil ->
        {:error, "Unknown tool: #{name}"}
    end
  end

  @doc "Execute multiple tool calls, returning a list of tool_result content blocks."
  def execute_all(tool_use_blocks, tools) do
    Enum.map(tool_use_blocks, fn %{"id" => id} = block ->
      {status, content} =
        case execute(block, tools) do
          {:ok, result} -> {:ok, result}
          {:error, reason} -> {:error, reason}
        end

      result = %{
        "type" => "tool_result",
        "tool_use_id" => id,
        "content" => content
      }

      if status == :error do
        Map.put(result, "is_error", true)
      else
        result
      end
    end)
  end

  defp execute_remote(tenant_id, tool_name, input) do
    case WorkerRegistry.dispatch_task(tenant_id, tool_name, input, from_pid: self()) do
      {:ok, task_id} ->
        WorkerRegistry.await_result(task_id)

      {:error, :no_worker} ->
        {:error, "No worker available for tool: #{tool_name}"}
    end
  end
end
