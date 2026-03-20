defmodule Norns.Workflow.Runtime do
  @moduledoc """
  Minimal phase-1 wrapper around the Lua sandbox runtime.
  """

  @type limits :: %{
          max_reductions: pos_integer(),
          max_time: pos_integer()
        }

  @type success :: %{
          result: term(),
          state: term(),
          limits: limits()
        }

  @type error :: %{
          type: atom(),
          message: String.t(),
          details: term()
        }

  @spec execute(String.t(), keyword()) :: {:ok, success()} | {:error, error()}
  def execute(script, opts \\ []) when is_binary(script) do
    state = Keyword.get(opts, :state, new_state())
    limits = limits(opts)

    try do
      script
      |> String.to_charlist()
      |> :luerl_sandbox.run(control_flags(limits), state)
      |> normalize_reply(limits)
    rescue
      exception ->
        {:error, error(:runtime_exception, Exception.message(exception), exception)}
    catch
      :exit, reason ->
        {:error, error(:sandbox_exit, "Lua execution exited", reason)}

      kind, reason ->
        {:error, error(:runtime_exception, "Lua execution failed", {kind, reason})}
    end
  end

  @spec new_state() :: term()
  def new_state do
    :luerl_sandbox.init()
  end

  @spec serialize_state(term()) :: {:ok, binary()} | {:error, error()}
  def serialize_state(state) do
    {:ok, :erlang.term_to_binary(state)}
  rescue
    exception ->
      {:error, error(:serialization_failed, Exception.message(exception), exception)}
  end

  @spec deserialize_state(binary()) :: {:ok, term()} | {:error, error()}
  def deserialize_state(serialized) when is_binary(serialized) do
    {:ok, :erlang.binary_to_term(serialized)}
  rescue
    exception ->
      {:error, error(:deserialization_failed, Exception.message(exception), exception)}
  end

  @spec limits(keyword()) :: limits()
  def limits(opts \\ []) do
    config = Application.get_env(:norns, __MODULE__, [])

    %{
      max_reductions: Keyword.get(opts, :max_reductions, Keyword.get(config, :max_reductions, 50_000)),
      max_time: Keyword.get(opts, :max_time, Keyword.get(config, :max_time, 100))
    }
  end

  defp control_flags(limits) do
    [
      {:max_reductions, limits.max_reductions},
      {:max_time, limits.max_time}
    ]
  end

  defp normalize_reply({:ok, values, next_state}, limits) do
    {:ok, %{result: unwrap_values(values), state: next_state, limits: limits}}
  end

  defp normalize_reply({{:ok, values, next_state}, _sandbox_state}, limits) do
    {:ok, %{result: unwrap_values(values), state: next_state, limits: limits}}
  end

  defp normalize_reply({reason, _sandbox_state}, _limits) do
    {:error, classify_error(reason)}
  end

  defp normalize_reply({:error, reason}, _limits) do
    {:error, classify_error(reason)}
  end

  defp normalize_reply({{:error, reason}, _sandbox_state}, _limits) do
    {:error, classify_error(reason)}
  end

  defp normalize_reply(other, _limits) do
    {:error, error(:unexpected_reply, "Unexpected Lua runtime reply", other)}
  end

  defp unwrap_values([]), do: nil
  defp unwrap_values([single]), do: single
  defp unwrap_values(values) when is_list(values), do: values
  defp unwrap_values(value), do: value

  defp classify_error(reason) do
    cond do
      terminated?(reason) ->
        error(:limit_exceeded, "Lua execution exceeded configured limits", reason)

      true ->
        error(:lua_error, "Lua execution returned an error", reason)
    end
  end

  defp terminated?(reason) do
    inspected = reason |> inspect() |> String.downcase()
    String.contains?(inspected, "timeout") or
      String.contains?(inspected, "time limit") or
      String.contains?(inspected, "reduction") or
      String.contains?(inspected, "killed")
  end

  defp error(type, message, details) do
    %{type: type, message: message, details: details}
  end
end
