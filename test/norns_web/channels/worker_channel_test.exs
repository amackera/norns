defmodule NornsWeb.WorkerChannelTest do
  use NornsWeb.ChannelCase, async: false

  alias NornsWeb.{WorkerSocket, WorkerChannel}
  alias Norns.Workers.WorkerRegistry

  setup do
    tenant = create_tenant()
    token = tenant.api_keys |> Map.values() |> List.first()

    {:ok, socket} = connect(WorkerSocket, %{"token" => token})

    %{socket: socket, tenant: tenant}
  end

  describe "join" do
    test "worker joins with tools", %{socket: socket} do
      tools = [%{"name" => "my_tool", "description" => "Does stuff", "input_schema" => %{}}]

      assert {:ok, _reply, _socket} =
               subscribe_and_join(socket, WorkerChannel, "worker:lobby", %{
                 "worker_id" => "test-worker",
                 "tools" => tools
               })

      # Cleanup
      WorkerRegistry.unregister_worker(socket.assigns.tenant_id, "test-worker")
    end

    test "rejects join without worker_id", %{socket: socket} do
      assert {:error, %{reason: "missing worker_id and tools"}} =
               subscribe_and_join(socket, WorkerChannel, "worker:lobby", %{})
    end
  end

  describe "tool_result" do
    test "delivers result to waiting process", %{socket: socket, tenant: tenant} do
      tools = [%{"name" => "rpc_tool", "description" => "RPC", "input_schema" => %{}}]

      {:ok, _, socket} =
        subscribe_and_join(socket, WorkerChannel, "worker:lobby", %{
          "worker_id" => "rpc-worker",
          "tools" => tools
        })

      # Dispatch a task from a test "agent"
      {:ok, task_id} =
        WorkerRegistry.dispatch_task(tenant.id, "rpc_tool", %{"arg" => "val"}, from_pid: self())

      # Simulate worker responding
      push(socket, "tool_result", %{
        "task_id" => task_id,
        "status" => "ok",
        "result" => "rpc done"
      })

      # Wait a bit for the message to be processed
      Process.sleep(100)

      assert {:ok, "rpc done"} = WorkerRegistry.await_result(task_id, 1000)

      WorkerRegistry.unregister_worker(tenant.id, "rpc-worker")
    end
  end

  describe "socket authentication" do
    test "rejects connection without token" do
      assert :error = connect(WorkerSocket, %{})
    end

    test "rejects connection with invalid token" do
      assert :error = connect(WorkerSocket, %{"token" => "bad"})
    end
  end
end
