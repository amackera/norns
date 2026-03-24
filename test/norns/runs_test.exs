defmodule Norns.RunsTest do
  use Norns.DataCase, async: true

  alias Norns.Runs
  alias Norns.Runtime.Events

  test "create_run/1 and append_event/2 with sequencing" do
    tenant = create_tenant()
    agent = create_agent(tenant)

    {:ok, run} =
      Runs.create_run(%{
        tenant_id: tenant.id,
        agent_id: agent.id,
        trigger_type: "external",
        status: "pending"
      })

    assert run.status == "pending"

    {:ok, e1} = Runs.append_event(run, elem(Events.run_started(), 1))

    {:ok, e2} =
      Runs.append_event(
        run,
        elem(
          Events.llm_response(%{
            "content" => [%{"type" => "text", "text" => "hi"}],
            "stop_reason" => "end_turn",
            "usage" => %{},
            "step" => 1
          }),
          1
        )
      )

    assert e1.sequence == 1
    assert e2.sequence == 2

    events = Runs.list_events(run.id)
    assert length(events) == 2
    assert Enum.map(events, & &1.event_type) == ["run_started", "llm_response"]
    assert Enum.all?(events, &(&1.payload["schema_version"] == 1))
  end

  test "update_run/2 transitions status" do
    tenant = create_tenant()
    agent = create_agent(tenant)

    {:ok, run} =
      Runs.create_run(%{tenant_id: tenant.id, agent_id: agent.id, trigger_type: "external"})

    {:ok, run} = Runs.update_run(run, %{status: "running"})
    assert run.status == "running"

    {:ok, run} = Runs.update_run(run, %{status: "completed", output: "done"})
    assert run.status == "completed"
    assert run.output == "done"
  end

  test "rejects invalid typed payloads" do
    tenant = create_tenant()
    agent = create_agent(tenant)

    {:ok, run} =
      Runs.create_run(%{
        tenant_id: tenant.id,
        agent_id: agent.id,
        trigger_type: "external",
        status: "pending"
      })

    assert {:error, %{payload: "step must be an integer"}} =
             Runs.append_event(run, %{
               event_type: "llm_request",
               payload: %{"step" => "bad", "message_count" => 1}
             })
  end
end
