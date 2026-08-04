defmodule Norns.Agents.SubagentPolicy do
  @moduledoc """
  Authorization policy for an agent's use of the `launch_agent` and
  `list_agents` built-ins.

  Parsed from an agent's `model_config` under the `"subagents"` key:

      {
        "subagents": {
          "mode": "allowlist",
          "allowed_agents": ["hello-bot"],
          "allow_list_agents": false
        }
      }

  Modes:

    * `:open` — may launch any agent in the same tenant (the default, and the
      behaviour before this policy existed)
    * `:allowlist` — may launch only the agents named in `allowed_agents`
    * `:disabled` — may not launch sub-agents at all

  `allow_list_agents` controls whether `list_agents` is permitted.

  Defaults are deliberately permissive so that adding the policy doesn't change
  behaviour for agents that don't configure it.
  """

  defstruct mode: :open, allowed_agents: [], allow_list_agents: true

  @type mode :: :open | :allowlist | :disabled

  @type t :: %__MODULE__{
          mode: mode(),
          allowed_agents: [String.t()],
          allow_list_agents: boolean()
        }

  @doc "Parse a policy out of an agent's `model_config`. Unknown values fall back to the permissive default."
  @spec from_config(map() | nil) :: t()
  def from_config(config) when is_map(config) do
    case Map.get(config, "subagents") do
      settings when is_map(settings) ->
        %__MODULE__{
          mode: parse_mode(Map.get(settings, "mode")),
          allowed_agents: parse_allowed(Map.get(settings, "allowed_agents")),
          allow_list_agents: parse_boolean(Map.get(settings, "allow_list_agents"), true)
        }

      _ ->
        %__MODULE__{}
    end
  end

  def from_config(_), do: %__MODULE__{}

  @doc """
  Whether this agent may launch `target_name`.

  Returns `:ok`, or `{:error, reason}` where reason is a stable code suitable
  for the audit event: `"disabled"` or `"not_allowlisted"`.
  """
  @spec authorize_launch(t(), String.t()) :: :ok | {:error, String.t()}
  def authorize_launch(%__MODULE__{mode: :disabled}, _target_name), do: {:error, "disabled"}

  def authorize_launch(%__MODULE__{mode: :allowlist, allowed_agents: allowed}, target_name) do
    if target_name in allowed, do: :ok, else: {:error, "not_allowlisted"}
  end

  def authorize_launch(%__MODULE__{mode: :open}, _target_name), do: :ok

  @doc """
  Whether this agent may enumerate other agents.

  Returns `:ok` or `{:error, "list_agents_disabled"}`.
  """
  @spec authorize_list(t()) :: :ok | {:error, String.t()}
  def authorize_list(%__MODULE__{allow_list_agents: true}), do: :ok
  def authorize_list(%__MODULE__{}), do: {:error, "list_agents_disabled"}

  defp parse_mode("allowlist"), do: :allowlist
  defp parse_mode("disabled"), do: :disabled
  defp parse_mode(_), do: :open

  defp parse_allowed(names) when is_list(names), do: Enum.filter(names, &is_binary/1)
  defp parse_allowed(_), do: []

  defp parse_boolean(value, _default) when is_boolean(value), do: value
  defp parse_boolean(_value, default), do: default
end
