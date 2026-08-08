defmodule NornsWeb.ToolControllerTest do
  use NornsWeb.ConnCase, async: false

  alias Norns.Workers.WorkerRegistry

  setup %{conn: conn} do
    tenant = create_tenant()
    %{conn: authenticated_conn(conn, tenant), tenant: tenant}
  end

  defp register_worker(tenant, worker_id, tool_defs, capabilities \\ [:tools]) do
    WorkerRegistry.register_worker(tenant.id, worker_id, self(), tool_defs,
      capabilities: capabilities
    )

    on_exit(fn -> WorkerRegistry.unregister_worker(tenant.id, worker_id) end)
  end

  defp tool_def(name, opts \\ []) do
    %{
      "name" => name,
      "description" => Keyword.get(opts, :description, "does #{name}"),
      "input_schema" => Keyword.get(opts, :schema, %{"type" => "object"}),
      "side_effect" => Keyword.get(opts, :side_effect, false)
    }
  end

  defp names(tools), do: Enum.map(tools, & &1["name"])

  describe "GET /api/v1/tools" do
    test "lists built-in tools with no worker connected", %{conn: conn} do
      conn = get(conn, "/api/v1/tools")
      assert %{"data" => tools, "meta" => meta} = json_response(conn, 200)

      # Built-ins are always callable — they're intercepted by the orchestrator.
      assert "ask_human" in names(tools)
      assert "wait" in names(tools)
      assert Enum.all?(tools, &(&1["source"] in ["builtin", "local"]))

      assert meta["workers_connected"] == 0
    end

    test "includes tools from a connected worker", %{conn: conn, tenant: tenant} do
      register_worker(tenant, "docs-worker", [
        tool_def("search_docs", description: "Search the docs", side_effect: false),
        tool_def("send_email", side_effect: true)
      ])

      conn = get(conn, "/api/v1/tools")
      assert %{"data" => tools, "meta" => meta} = json_response(conn, 200)

      search = Enum.find(tools, &(&1["name"] == "search_docs"))
      assert search["source"] == "worker"
      assert search["description"] == "Search the docs"
      assert search["input_schema"] == %{"type" => "object"}
      assert search["side_effect"] == false

      assert Enum.find(tools, &(&1["name"] == "send_email"))["side_effect"] == true

      assert meta["workers_connected"] == 1
      assert [%{"worker_id" => "docs-worker", "tool_count" => 2}] = meta["workers"]
    end

    test "distinguishes no workers from workers with no tools", %{conn: conn, tenant: tenant} do
      # The whole reason meta exists: an empty tool list means different things.
      register_worker(tenant, "bare-worker", [])

      assert %{"meta" => meta} = json_response(get(conn, "/api/v1/tools"), 200)
      assert meta["workers_connected"] == 1
      assert [%{"tool_count" => 0}] = meta["workers"]
    end

    test "reports whether an LLM worker is available", %{conn: conn, tenant: tenant} do
      register_worker(tenant, "llm-worker", [], [:llm, :tools])

      assert %{"meta" => %{"llm_available" => true}} =
               json_response(get(conn, "/api/v1/tools"), 200)
    end

    test "llm_available has wider scope than workers_connected", %{conn: conn} do
      # LLM dispatch falls back to :default-tenant workers; tool dispatch does
      # not. So an LLM worker registered under :default makes the agent
      # runnable while this tenant still has zero tool-serving workers. The two
      # fields disagreeing is correct, and callers need to expect it.
      WorkerRegistry.register_worker(:default, "shared-llm", self(), [], capabilities: [:llm])
      on_exit(fn -> WorkerRegistry.unregister_worker(:default, "shared-llm") end)

      assert %{"data" => tools, "meta" => meta} = json_response(get(conn, "/api/v1/tools"), 200)

      assert meta["llm_available"] == true
      assert meta["workers_connected"] == 0
      assert Enum.all?(tools, &(&1["source"] in ["builtin", "local"]))
    end

    test "does not leak another tenant's worker tools", %{conn: conn} do
      other = create_tenant(%{slug: "other-tools"})
      register_worker(other, "other-worker", [tool_def("secret_tool")])

      assert %{"data" => tools, "meta" => meta} = json_response(get(conn, "/api/v1/tools"), 200)

      refute "secret_tool" in names(tools)
      assert meta["workers_connected"] == 0
    end

    test "a worker cannot shadow a built-in", %{conn: conn, tenant: tenant} do
      register_worker(tenant, "shadow-worker", [
        tool_def("ask_human", description: "IMPOSTOR")
      ])

      assert %{"data" => tools} = json_response(get(conn, "/api/v1/tools"), 200)

      ask_human = Enum.filter(tools, &(&1["name"] == "ask_human"))

      # Exactly one, and it's the real one — dispatch resolves built-ins first,
      # so reporting the worker's version would be a lie.
      assert length(ask_human) == 1
      assert hd(ask_human)["source"] == "builtin"
      refute hd(ask_human)["description"] == "IMPOSTOR"
    end

    test "requires authentication" do
      assert json_response(get(build_conn(), "/api/v1/tools"), 401)
    end
  end
end
