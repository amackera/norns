defmodule Norns.Agents.AgentDef do
  @moduledoc """
  Declarative agent definition. Configures model, tools, checkpoint policy,
  and failure recovery for an agent process.
  """

  @enforce_keys [:model, :system_prompt]
  defstruct [
    :model,
    :system_prompt,
    tools: [],
    checkpoint_policy: :on_tool_call,
    max_steps: 50,
    on_failure: :stop
  ]

  @type checkpoint_policy :: :every_step | :on_tool_call | :manual
  @type failure_policy :: :stop | :retry_last_step

  @type t :: %__MODULE__{
          model: String.t(),
          system_prompt: String.t(),
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
      tools: module_tools ++ extra_tools,
      max_steps: agent.max_steps || 50,
      checkpoint_policy: parse_checkpoint_policy(config),
      on_failure: parse_failure_policy(config)
    }
  end

  defp parse_checkpoint_policy(%{"checkpoint_policy" => "every_step"}), do: :every_step
  defp parse_checkpoint_policy(%{"checkpoint_policy" => "manual"}), do: :manual
  defp parse_checkpoint_policy(_), do: :on_tool_call

  defp parse_failure_policy(%{"on_failure" => "retry_last_step"}), do: :retry_last_step
  defp parse_failure_policy(_), do: :stop
end
