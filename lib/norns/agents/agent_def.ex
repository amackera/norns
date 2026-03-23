defmodule Norns.Agents.AgentDef do
  @moduledoc """
  Declarative agent definition. Configures model, tools, checkpoint policy,
  and failure recovery for an agent process.
  """

  @enforce_keys [:model, :system_prompt]
  defstruct [
    :model,
    :system_prompt,
    mode: :task,
    context_strategy: :sliding_window,
    context_window: 20,
    tools: [],
    checkpoint_policy: :on_tool_call,
    max_steps: 50,
    on_failure: :stop
  ]

  @type mode :: :task | :conversation
  @type context_strategy :: :sliding_window | :none
  @type checkpoint_policy :: :every_step | :on_tool_call | :manual
  @type failure_policy :: :stop | :retry_last_step

  @type t :: %__MODULE__{
          model: String.t(),
          system_prompt: String.t(),
          mode: mode(),
          context_strategy: context_strategy(),
          context_window: pos_integer(),
          tools: [Norns.Tools.Tool.t()],
          checkpoint_policy: checkpoint_policy(),
          max_steps: pos_integer(),
          on_failure: failure_policy()
        }

  @doc "Build an AgentDef from an Agent schema record and optional tool modules."
  def from_agent(%Norns.Agents.Agent{} = agent, opts \\ []) do
    tool_modules = Keyword.get(opts, :tool_modules, [])
    extra_tools = Keyword.get(opts, :tools, [])
    config = agent.model_config || %{}

    module_tools = Enum.map(tool_modules, fn mod -> mod.__tool__() end)

    %__MODULE__{
      model: agent.model,
      system_prompt: agent.system_prompt,
      mode: parse_mode(config),
      context_strategy: parse_context_strategy(config),
      context_window: parse_context_window(config),
      tools: module_tools ++ extra_tools,
      max_steps: agent.max_steps || 50,
      checkpoint_policy: parse_checkpoint_policy(config),
      on_failure: parse_failure_policy(config)
    }
  end

  defp parse_mode(%{"mode" => "conversation"}), do: :conversation
  defp parse_mode(_), do: :task

  defp parse_context_strategy(%{"context_strategy" => "none"}), do: :none
  defp parse_context_strategy(_), do: :sliding_window

  defp parse_context_window(%{"context_window" => value}) when is_integer(value) and value > 0,
    do: value

  defp parse_context_window(%{"context_window" => value}) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> 20
    end
  end

  defp parse_context_window(_), do: 20

  defp parse_checkpoint_policy(%{"checkpoint_policy" => "every_step"}), do: :every_step
  defp parse_checkpoint_policy(%{"checkpoint_policy" => "manual"}), do: :manual
  defp parse_checkpoint_policy(_), do: :on_tool_call

  defp parse_failure_policy(%{"on_failure" => "retry_last_step"}), do: :retry_last_step
  defp parse_failure_policy(_), do: :stop
end
