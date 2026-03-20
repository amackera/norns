defmodule Norns.Workflow.RuntimeTest do
  use ExUnit.Case, async: true

  alias Norns.Workflow.Runtime

  describe "execute/2" do
    test "executes a basic Lua script successfully" do
      assert {:ok, execution} = Runtime.execute("return 1 + 2")
      assert execution.result == 3
      assert execution.limits.max_reductions > 0
      assert execution.limits.max_time > 0
      assert execution.state
    end

    test "terminates an infinite loop when limits are exceeded" do
      assert {:error, error} =
               Runtime.execute("while true do end", max_reductions: 1_000, max_time: 25)

      assert error.type == :limit_exceeded
    end
  end

  describe "state serialization" do
    test "sandbox state can be serialized and restored for the current phase-1 state shape" do
      state = Runtime.new_state()

      assert {:ok, serialized} = Runtime.serialize_state(state)
      assert is_binary(serialized)

      assert {:ok, restored_state} = Runtime.deserialize_state(serialized)

      assert {:ok, execution} = Runtime.execute("return 40 + 2", state: restored_state)
      assert execution.result == 42
    end
  end
end
