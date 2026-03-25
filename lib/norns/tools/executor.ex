defmodule Norns.Tools.Executor do
  @moduledoc "Matches tool_use blocks to registered tools and executes them."

  alias Norns.Runs
  alias Norns.Tools.Idempotency
  alias Norns.Tools.Tool
  alias Norns.Workers.WorkerRegistry

  @doc """
  Execute a tool call. Finds the matching tool by name and calls its handler.
  Supports both local and remote (worker-provided) tools.
  """
  def execute(%{"name" => name, "input" => input} = block, tools, opts \\ []) when is_list(tools) do
    case Enum.find(tools, &(&1.name == name)) do
      %Tool{source: {:remote, tenant_id}} = tool ->
        with_tool_context(block, tools, opts, fn context ->
          maybe_reuse_result(tool, input, context, fn ->
            execute_remote(tenant_id, name, input, context)
          end)
        end)

      %Tool{} = tool ->
        with_tool_context(block, tools, opts, fn context ->
          maybe_reuse_result(tool, input, context, fn ->
            try do
              tool.handler.(input)
            rescue
              e -> {:error, "Tool execution error: #{Exception.message(e)}"}
            end
          end)
        end)

      nil ->
        {:error, "Unknown tool: #{name}"}
    end
  end

  @doc "Execute multiple tool calls, returning a list of tool_result content blocks."
  def execute_all(tool_use_blocks, tools, opts \\ []) do
    Enum.map(tool_use_blocks, fn %{"id" => id} = block ->
      execution = execute(block, tools, opts)

      {status, content, metadata} =
        case execution do
          {:ok, result, metadata} -> {:ok, result, metadata}
          {:ok, result} -> {:ok, result, %{}}
          {:error, reason, metadata} -> {:error, reason, metadata}
          {:error, reason} -> {:error, reason, %{}}
        end

      result = %{
        "type" => "tool_result",
        "tool_use_id" => id,
        "content" => content
      }

      result =
        case metadata do
          %{"idempotency_key" => key} when is_binary(key) -> Map.put(result, "idempotency_key", key)
          _ -> result
        end

      result =
        if metadata["duplicate_detected"] do
          Map.merge(result, %{
            "duplicate_detected" => true,
            "duplicate_original_event_sequence" => metadata["original_event_sequence"],
            "duplicate_resolution" => metadata["resolution"],
            "name" => block["name"]
          })
        else
          result
        end

      if status == :error do
        Map.put(result, "is_error", true)
      else
        result
      end
    end)
  end

  defp execute_remote(tenant_id, tool_name, input, context) do
    task_input =
      case context.idempotency_key do
        key when is_binary(key) -> Map.put(input, "_norns_idempotency_key", key)
        _ -> input
      end

    case WorkerRegistry.dispatch_task(tenant_id, tool_name, task_input, from_pid: self()) do
      {:ok, task_id} ->
        WorkerRegistry.await_result(task_id)

      {:error, :no_worker} ->
        {:error, "No worker available for tool: #{tool_name}"}
    end
  end

  defp with_tool_context(block, tools, opts, fun) do
    tool = Enum.find(tools, &(&1.name == block["name"]))
    context = build_context(opts, block, tool)
    existing_context = Process.get(:norns_tool_context)
    Process.put(:norns_tool_context, merge_context(existing_context, context))

    try do
      fun.(context)
    after
      restore_context(existing_context)
    end
  end

  defp build_context(opts, block, %Tool{} = tool) do
    run = Keyword.get(opts, :run)
    step = Keyword.get(opts, :step)

    if run && is_integer(step) do
      Idempotency.context(run, step, block, tool)
    else
      %{run_id: nil, step: step, tool_use_id: block["id"], tool_name: block["name"], side_effect?: false, idempotency_key: nil}
    end
  end

  defp build_context(_opts, block, _tool) do
    %{run_id: nil, step: nil, tool_use_id: block["id"], tool_name: block["name"], side_effect?: false, idempotency_key: nil}
  end

  defp maybe_reuse_result(%Tool{} = tool, _input, %{run_id: run_id, side_effect?: true, idempotency_key: key}, execute_fun)
       when is_integer(run_id) and is_binary(key) do
    case Runs.find_duplicate_side_effect(run_id, key) do
      nil ->
        result = execute_fun.()
        attach_idempotency_metadata(result, key)

      event ->
        {:ok, event.payload["content"],
         %{
           "idempotency_key" => key,
           "duplicate_detected" => true,
           "original_event_sequence" => event.sequence,
           "resolution" => "reused_persisted_result",
           "side_effect" => tool.side_effect?
         }}
    end
  end

  defp maybe_reuse_result(_tool, _input, _context, execute_fun), do: execute_fun.()

  defp attach_idempotency_metadata({status, content}, key) when status in [:ok, :error] do
    {status, content, %{"idempotency_key" => key}}
  end

  defp attach_idempotency_metadata(other, _key), do: other

  defp merge_context(%{} = existing, context), do: Map.merge(existing, context)
  defp merge_context(_existing, context), do: context

  defp restore_context(nil), do: Process.delete(:norns_tool_context)
  defp restore_context(context), do: Process.put(:norns_tool_context, context)
end
