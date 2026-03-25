defmodule Norns.Workers.DefaultWorker do
  @moduledoc """
  Built-in worker that runs in the same BEAM VM as the orchestrator.
  Handles LLM calls and built-in tool execution. Registered with the
  WorkerRegistry on boot — the agent process dispatches to it like
  any other worker, but execution is local (no network hop).

  For self-hosted mode, this is all you need. For production, users
  run their own workers with their own tools and API keys.
  """

  use GenServer

  require Logger

  alias Norns.LLM
  alias Norns.Tools.Executor
  alias Norns.Workers.WorkerRegistry

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # Register with WorkerRegistry as a local worker
    tools = Norns.Tools.Registry.all_tools()

    tool_defs =
      Enum.map(tools, fn tool ->
        %{
          "name" => tool.name,
          "description" => tool.description,
          "input_schema" => tool.input_schema,
          "side_effect" => Map.get(tool, :side_effect?, false)
        }
      end)

    WorkerRegistry.register_worker(
      :default,
      "default-worker",
      self(),
      tool_defs,
      capabilities: [:llm, :tools]
    )

    {:ok, %{tools: tools}}
  end

  @impl true
  def handle_info({:push_tool_task, task}, state) do
    # Execute tool in a spawned task so we don't block the worker
    _worker_pid = self()

    Task.start(fn ->
      result = execute_tool(task, state.tools)

      WorkerRegistry.deliver_result(task[:task_id] || task["task_id"], %{
        "status" => if(match?({:ok, _}, result), do: "ok", else: "error"),
        "result" => elem(result, 1),
        "error" => if(match?({:error, _}, result), do: elem(result, 1))
      })
    end)

    {:noreply, state}
  end

  def handle_info({:llm_task, task}, state) do
    _worker_pid = self()

    Task.start(fn ->
      result = execute_llm(task)

      WorkerRegistry.deliver_result(task.task_id, result)
    end)

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- LLM Execution --

  defp execute_llm(task) do
    api_key = task.api_key
    model = task.model
    system_prompt = task.system_prompt
    messages = task.messages
    opts = task.opts || []

    case LLM.chat(api_key, model, system_prompt, messages, opts) do
      {:ok, response} ->
        %{
          "status" => "ok",
          "content" => response.content,
          "stop_reason" => response.stop_reason,
          "usage" => %{
            "input_tokens" => response.usage.input_tokens,
            "output_tokens" => response.usage.output_tokens
          }
        }

      {:error, reason} ->
        %{"status" => "error", "error" => reason}
    end
  end

  # -- Tool Execution --

  defp execute_tool(task, tools) do
    tool_name = task[:tool_name] || task["tool_name"]
    input = task[:input] || task["input"]

    block = %{
      "name" => tool_name,
      "input" => input,
      "id" => task[:task_id] || task["task_id"]
    }

    case Executor.execute(block, tools) do
      {:ok, result} -> {:ok, result}
      {:ok, result, _meta} -> {:ok, result}
      {:error, reason} -> {:error, reason}
      {:error, reason, _meta} -> {:error, reason}
    end
  end
end
