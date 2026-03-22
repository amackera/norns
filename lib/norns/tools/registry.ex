defmodule Norns.Tools.Registry do
  @moduledoc "Registry of locally available tools. ETS-backed for fast reads."

  @table __MODULE__

  def init do
    if :ets.info(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set])
    end

    :ok
  end

  @doc "Register a tool module implementing Norns.Tools.Behaviour."
  def register(module) when is_atom(module) do
    tool = module.__tool__()
    :ets.insert(@table, {tool.name, module, tool})
    :ok
  end

  @doc "Get a tool struct by name."
  def get(name) when is_binary(name) do
    case :ets.lookup(@table, name) do
      [{^name, _module, tool}] -> {:ok, tool}
      [] -> :error
    end
  end

  @doc "List all registered tool names and modules."
  def list do
    :ets.tab2list(@table)
    |> Enum.map(fn {name, module, _tool} -> {name, module} end)
  end

  @doc "Return all registered tools as a list of %Tool{} structs."
  def all_tools do
    :ets.tab2list(@table)
    |> Enum.map(fn {_name, _module, tool} -> tool end)
  end
end
