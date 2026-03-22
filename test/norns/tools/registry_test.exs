defmodule Norns.Tools.RegistryTest do
  use ExUnit.Case, async: false

  alias Norns.Tools.{Registry, WebSearch}

  # Registry is initialized by the application, but reset for isolation
  setup do
    Registry.init()
    :ets.delete_all_objects(Registry)
    :ok
  end

  describe "register/1" do
    test "registers a tool module" do
      assert :ok = Registry.register(WebSearch)
    end
  end

  describe "get/1" do
    test "returns registered tool" do
      Registry.register(WebSearch)
      assert {:ok, tool} = Registry.get("web_search")
      assert tool.name == "web_search"
    end

    test "returns :error for unknown tool" do
      assert :error = Registry.get("nonexistent")
    end
  end

  describe "list/0" do
    test "lists registered tools" do
      Registry.register(WebSearch)
      entries = Registry.list()
      assert {"web_search", WebSearch} in entries
    end
  end

  describe "all_tools/0" do
    test "returns list of Tool structs" do
      Registry.register(WebSearch)
      tools = Registry.all_tools()
      assert length(tools) == 1
      assert hd(tools).name == "web_search"
    end
  end
end
