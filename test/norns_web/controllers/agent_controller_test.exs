defmodule NornsWeb.AgentControllerTest do
  use NornsWeb.ConnCase, async: false

  alias Norns.LLM.Fake

  setup %{conn: conn} do
    tenant = create_tenant()
    conn = authenticated_conn(conn, tenant)
    %{conn: conn, tenant: tenant}
  end

  describe "POST /api/v1/agents" do
    test "creates an agent", %{conn: conn} do
      params = %{
        "name" => "test-agent",
        "system_prompt" => "You are helpful.",
        "status" => "idle"
      }

      conn = post(conn, "/api/v1/agents", params)
      assert %{"data" => %{"id" => _, "name" => "test-agent"}} = json_response(conn, 201)
    end

    test "returns 422 for invalid params", %{conn: conn} do
      conn = post(conn, "/api/v1/agents", %{"name" => ""})
      assert %{"error" => _} = json_response(conn, 422)
    end
  end

  describe "GET /api/v1/agents" do
    test "lists agents for tenant", %{conn: conn, tenant: tenant} do
      create_agent(tenant)
      create_agent(tenant)

      conn = get(conn, "/api/v1/agents")
      assert %{"data" => agents} = json_response(conn, 200)
      assert length(agents) == 2
    end
  end

  describe "GET /api/v1/agents/:id" do
    test "shows an agent", %{conn: conn, tenant: tenant} do
      agent = create_agent(tenant)
      conn = get(conn, "/api/v1/agents/#{agent.id}")
      assert %{"data" => %{"id" => id}} = json_response(conn, 200)
      assert id == agent.id
    end

    test "returns 404 for non-existent agent", %{conn: conn} do
      conn = get(conn, "/api/v1/agents/999999")
      assert json_response(conn, 404)
    end
  end

  describe "POST /api/v1/agents/:id/start" do
    test "starts an agent process", %{conn: conn, tenant: tenant} do
      agent = create_agent(tenant)
      conn = post(conn, "/api/v1/agents/#{agent.id}/start")
      assert %{"status" => "started"} = json_response(conn, 200)

      # Cleanup
      Norns.Agents.Registry.stop_agent(tenant.id, agent.id)
    end

    test "returns 409 if already running", %{conn: conn, tenant: tenant} do
      agent = create_agent(tenant)
      Norns.Agents.Registry.start_agent(agent.id, tenant.id)

      conn = post(conn, "/api/v1/agents/#{agent.id}/start")
      assert %{"error" => "agent already running"} = json_response(conn, 409)

      Norns.Agents.Registry.stop_agent(tenant.id, agent.id)
    end
  end

  describe "DELETE /api/v1/agents/:id/stop" do
    test "stops a running agent", %{conn: conn, tenant: tenant} do
      agent = create_agent(tenant)
      Norns.Agents.Registry.start_agent(agent.id, tenant.id)

      conn = delete(conn, "/api/v1/agents/#{agent.id}/stop")
      assert %{"status" => "stopped"} = json_response(conn, 200)
    end

    test "returns 404 if not running", %{conn: conn, tenant: tenant} do
      agent = create_agent(tenant)
      conn = delete(conn, "/api/v1/agents/#{agent.id}/stop")
      assert %{"error" => "agent not running"} = json_response(conn, 404)
    end
  end

  describe "GET /api/v1/agents/:id/status" do
    test "returns running status", %{conn: conn, tenant: tenant} do
      agent = create_agent(tenant)
      Norns.Agents.Registry.start_agent(agent.id, tenant.id)

      conn = get(conn, "/api/v1/agents/#{agent.id}/status")
      assert %{"data" => %{"status" => "idle"}} = json_response(conn, 200)

      Norns.Agents.Registry.stop_agent(tenant.id, agent.id)
    end

    test "returns stopped status when not running", %{conn: conn, tenant: tenant} do
      agent = create_agent(tenant)
      conn = get(conn, "/api/v1/agents/#{agent.id}/status")
      assert %{"data" => %{"status" => "stopped"}} = json_response(conn, 200)
    end
  end

  describe "POST /api/v1/agents/:id/messages" do
    test "accepts a message and starts the agent if needed", %{conn: conn, tenant: tenant} do
      Fake.set_responses([
        %{content: [%{"type" => "text", "text" => "ok"}], stop_reason: "end_turn"}
      ])

      agent = create_agent(tenant)
      conn = post(conn, "/api/v1/agents/#{agent.id}/messages", %{"content" => "hello"})
      assert %{"status" => "accepted"} = json_response(conn, 202)

      Process.sleep(100)
      Norns.Agents.Registry.stop_agent(tenant.id, agent.id)
    end

    test "passes an optional conversation_key through", %{conn: conn, tenant: tenant} do
      Fake.set_responses([
        %{content: [%{"type" => "text", "text" => "ok"}], stop_reason: "end_turn"}
      ])

      agent =
        create_agent(tenant, %{
          model_config: %{"mode" => "conversation"}
        })

      conn =
        post(conn, "/api/v1/agents/#{agent.id}/messages", %{
          "content" => "hello",
          "conversation_key" => "slack:C123"
        })

      assert %{"status" => "accepted"} = json_response(conn, 202)
      Process.sleep(100)

      conversation = Norns.Conversations.get_conversation_by_agent_key!(agent.id, "slack:C123")
      assert conversation.message_count == 2

      Norns.Agents.Registry.stop_agent(tenant.id, agent.id, "slack:C123")
    end

    test "returns 404 for unknown agent", %{conn: conn} do
      conn = post(conn, "/api/v1/agents/999999/messages", %{"content" => "hello"})
      assert %{"error" => "not found"} = json_response(conn, 404)
    end
  end

  describe "conversation endpoints" do
    test "lists, shows, and deletes conversations for an agent", %{conn: conn, tenant: tenant} do
      agent = create_agent(tenant)
      {:ok, conversation} =
        Norns.Conversations.create_conversation(%{
          agent_id: agent.id,
          tenant_id: tenant.id,
          key: "slack:C123",
          messages: [%{role: "user", content: "hi"}]
        })

      conn = get(conn, "/api/v1/agents/#{agent.id}/conversations")
      assert %{"data" => [%{"key" => "slack:C123"}]} = json_response(conn, 200)

      conn = get(conn, "/api/v1/agents/#{agent.id}/conversations/#{conversation.key}")
      assert %{"data" => %{"key" => "slack:C123"}} = json_response(conn, 200)

      conn = delete(conn, "/api/v1/agents/#{agent.id}/conversations/#{conversation.key}")
      assert %{"status" => "deleted"} = json_response(conn, 200)
    end
  end

  describe "GET /api/v1/agents/:id/runs" do
    test "lists runs for agent", %{conn: conn, tenant: tenant} do
      agent = create_agent(tenant)

      Norns.Runs.create_run(%{
        agent_id: agent.id,
        tenant_id: tenant.id,
        trigger_type: "message",
        input: %{},
        status: "completed"
      })

      conn = get(conn, "/api/v1/agents/#{agent.id}/runs")
      assert %{"data" => [_run]} = json_response(conn, 200)
    end
  end

  describe "authentication" do
    test "returns 401 without token" do
      conn = build_conn() |> get("/api/v1/agents")
      assert json_response(conn, 401)
    end

    test "returns 401 with invalid token" do
      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer invalid-token")
        |> get("/api/v1/agents")

      assert json_response(conn, 401)
    end
  end
end
