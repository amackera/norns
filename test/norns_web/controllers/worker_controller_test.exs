defmodule NornsWeb.WorkerControllerTest do
  use NornsWeb.ConnCase, async: false

  alias Norns.Workers.WorkerRegistry

  setup %{conn: conn} do
    tenant = create_tenant()
    %{conn: authenticated_conn(conn, tenant), tenant: tenant}
  end

  defp register_worker(tenant, worker_id, opts \\ []) do
    WorkerRegistry.register_worker(
      tenant.id,
      worker_id,
      self(),
      Keyword.get(opts, :tools, []),
      capabilities: Keyword.get(opts, :capabilities, [:tools]),
      gard: Keyword.get(opts, :gard)
    )

    on_exit(fn -> WorkerRegistry.unregister_worker(tenant.id, worker_id) end)
  end

  defp tool_def(name) do
    %{"name" => name, "description" => "does #{name}", "input_schema" => %{"type" => "object"}}
  end

  describe "GET /api/v1/workers" do
    test "empty when no worker is connected", %{conn: conn} do
      assert %{"data" => []} = json_response(get(conn, "/api/v1/workers"), 200)
    end

    test "lists a connected worker with capabilities, tool count, and gard", %{
      conn: conn,
      tenant: tenant
    } do
      register_worker(tenant, "slack-connector",
        tools: [tool_def("post_to_slack"), tool_def("list_slack_channels")],
        capabilities: [:llm, :tools]
      )

      assert %{"data" => [worker]} = json_response(get(conn, "/api/v1/workers"), 200)
      assert worker["worker_id"] == "slack-connector"
      assert Enum.sort(worker["capabilities"]) == ["llm", "tools"]
      assert worker["tool_count"] == 2
      assert worker["gard"] == nil
    end

    test "includes the gard for a gard-bound worker", %{conn: conn, tenant: tenant} do
      register_worker(tenant, "coding-worker", gard: "gard_abc")

      assert %{"data" => [worker]} = json_response(get(conn, "/api/v1/workers"), 200)
      assert worker["gard"] == "gard_abc"
    end

    test "does not list another tenant's workers", %{conn: conn} do
      other = create_tenant()
      register_worker(other, "other-worker")

      assert %{"data" => []} = json_response(get(conn, "/api/v1/workers"), 200)
    end

    test "requires authentication" do
      conn = get(Phoenix.ConnTest.build_conn(), "/api/v1/workers")
      assert conn.status in [401, 403]
    end
  end
end
