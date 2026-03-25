defmodule NornsWeb.RunControllerTest do
  use NornsWeb.ConnCase, async: false

  setup %{conn: conn} do
    tenant = create_tenant()
    agent = create_agent(tenant)
    conn = authenticated_conn(conn, tenant)
    %{conn: conn, tenant: tenant, agent: agent}
  end

  describe "GET /api/v1/runs/:id" do
    test "shows a run", %{conn: conn, tenant: tenant, agent: agent} do
      {:ok, run} =
        Norns.Runs.create_run(%{
          agent_id: agent.id,
          tenant_id: tenant.id,
          trigger_type: "message",
          input: %{"msg" => "hi"},
          status: "completed",
          output: "hello"
        })

      conn = get(conn, "/api/v1/runs/#{run.id}")
      assert %{"data" => %{"id" => id, "status" => "completed"}} = json_response(conn, 200)
      assert id == run.id
    end

    test "includes failure inspector for failed runs", %{conn: conn, tenant: tenant, agent: agent} do
      {:ok, run} =
        Norns.Runs.create_run(%{
          agent_id: agent.id,
          tenant_id: tenant.id,
          trigger_type: "message",
          input: %{"msg" => "hi"},
          status: "failed",
          failure_metadata: %{
            "error_class" => "internal",
            "error_code" => "runtime_failure",
            "retry_decision" => "terminal"
          }
        })

      Norns.Runs.append_event(run, %{
        event_type: "checkpoint_saved",
        payload: %{"messages" => [%{role: "user", content: "hi"}], "step" => 1}
      })

      Norns.Runs.append_event(run, %{
        event_type: "run_failed",
        payload: %{
          "error" => "boom",
          "error_class" => "internal",
          "error_code" => "runtime_failure",
          "retry_decision" => "terminal"
        }
      })

      conn = get(conn, "/api/v1/runs/#{run.id}")
      assert %{"data" => %{"failure_inspector" => inspector, "failure_metadata" => metadata}} = json_response(conn, 200)
      assert inspector["error_class"] == "internal"
      assert inspector["error_code"] == "runtime_failure"
      assert inspector["retry_decision"] == "terminal"
      assert inspector["last_checkpoint"]["event_type"] == "checkpoint_saved"
      assert inspector["last_event"]["event_type"] == "run_failed"
      assert metadata["error_code"] == "runtime_failure"
    end

    test "returns 404 for non-existent run", %{conn: conn} do
      conn = get(conn, "/api/v1/runs/999999")
      assert json_response(conn, 404)
    end
  end

  describe "GET /api/v1/runs/:id/events" do
    test "returns event log", %{conn: conn, tenant: tenant, agent: agent} do
      {:ok, run} =
        Norns.Runs.create_run(%{
          agent_id: agent.id,
          tenant_id: tenant.id,
          trigger_type: "message",
          input: %{},
          status: "running"
        })

      Norns.Runs.append_event(run, %{event_type: "run_started", source: "system"})

      Norns.Runs.append_event(run, %{
        event_type: "llm_request",
        source: "system",
        payload: %{"step" => 1, "message_count" => 1}
      })

      conn = get(conn, "/api/v1/runs/#{run.id}/events")
      assert %{"data" => events} = json_response(conn, 200)
      assert length(events) == 2
      assert Enum.map(events, & &1["event_type"]) == ["run_started", "llm_request"]
    end
  end
end
