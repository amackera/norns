defmodule Norns.Agents.AgentDefTest do
  use Norns.DataCase, async: true

  alias Norns.Agents.AgentDef
  alias Norns.Tools.WebSearch

  describe "from_agent/2" do
    test "builds AgentDef from Agent schema" do
      tenant = create_tenant()
      agent = create_agent(tenant, %{model: "claude-sonnet-4-20250514", max_steps: 25})

      agent_def = AgentDef.from_agent(agent)

      assert agent_def.model == "claude-sonnet-4-20250514"
      assert agent_def.system_prompt == agent.system_prompt
      assert agent_def.max_steps == 25
      assert agent_def.checkpoint_policy == :on_tool_call
      assert agent_def.on_failure == :stop
      assert agent_def.tools == []
    end

    test "includes tool modules" do
      tenant = create_tenant()
      agent = create_agent(tenant)

      agent_def = AgentDef.from_agent(agent, tool_modules: [WebSearch])

      assert length(agent_def.tools) == 1
      assert hd(agent_def.tools).name == "web_search"
    end

    test "includes raw tool structs" do
      tenant = create_tenant()
      agent = create_agent(tenant)

      tool = WebSearch.__tool__()
      agent_def = AgentDef.from_agent(agent, tools: [tool])

      assert length(agent_def.tools) == 1
    end

    test "reads checkpoint_policy from model_config" do
      tenant = create_tenant()
      agent = create_agent(tenant, %{model_config: %{"checkpoint_policy" => "every_step"}})

      agent_def = AgentDef.from_agent(agent)
      assert agent_def.checkpoint_policy == :every_step
    end

    test "reads on_failure from model_config" do
      tenant = create_tenant()
      agent = create_agent(tenant, %{model_config: %{"on_failure" => "retry_last_step"}})

      agent_def = AgentDef.from_agent(agent)
      assert agent_def.on_failure == :retry_last_step
    end
  end
end
