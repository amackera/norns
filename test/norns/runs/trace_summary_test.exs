defmodule Norns.Runs.TraceSummaryTest do
  use Norns.DataCase, async: true

  alias Norns.Runs
  alias Norns.Runs.TraceSummary
  alias Norns.Runtime.Events

  setup do
    tenant = create_tenant()
    agent = create_agent(tenant, %{model: "claude-sonnet-5", max_steps: 10})
    %{tenant: tenant, agent: agent}
  end

  defp new_run(tenant, agent, attrs \\ %{}) do
    {:ok, run} =
      Runs.create_run(
        Map.merge(
          %{
            tenant_id: tenant.id,
            agent_id: agent.id,
            trigger_type: "message",
            status: "running",
            input: %{}
          },
          attrs
        )
      )

    run
  end

  # Events.* return {:ok, event}; append_event wants the event.
  defp append(run, {:ok, event}), do: Runs.append_event(run, event)

  defp llm_request(run, step, tools) do
    append(
      run,
      Events.llm_request(%{
        "step" => step,
        "message_count" => step,
        "model" => "claude-sonnet-5",
        "tools" => tools
      })
    )
  end

  defp tool_pair(run, step, name, args, content, is_error \\ false) do
    id = "call_#{step}_#{System.unique_integer([:positive])}"

    append(
      run,
      Events.tool_call(%{
        "tool_call_id" => id,
        "name" => name,
        "arguments" => args,
        "step" => step
      })
    )

    append(
      run,
      Events.tool_result(%{
        "tool_call_id" => id,
        "name" => name,
        "content" => content,
        "is_error" => is_error,
        "step" => step
      })
    )

    id
  end

  defp summary(run_id) do
    {:ok, s} = TraceSummary.build(run_id)
    s
  end

  defp signal(summary, kind), do: Enum.find(summary.signals, &(&1.kind == kind))

  describe "build/1" do
    test "returns not_found for an unknown run" do
      assert TraceSummary.build(-1) == {:error, :not_found}
    end

    test "summarizes a clean completed run", %{tenant: tenant, agent: agent} do
      run = new_run(tenant, agent)
      llm_request(run, 1, ["search_docs"])
      tool_pair(run, 1, "search_docs", %{"query" => "refunds"}, "found 3 results")
      append(run, Events.run_completed(%{"output" => "done"}))
      {:ok, run} = Runs.update_run(run, %{status: "completed"})

      s = summary(run.id)

      assert s.verdict == "completed"
      assert s.reason == "completed"
      assert s.counters.tool_calls == 1
      assert s.counters.llm_calls == 1
      assert s.counters.tool_errors == 0
      assert s.tools_used["search_docs"].calls == 1
      assert s.signals == []

      [entry] = s.timeline
      assert entry.call == ~s|search_docs(query="refunds")|
      assert entry.result == "found 3 results"
    end

    test "carries agent metadata and lineage", %{tenant: tenant, agent: agent} do
      parent = new_run(tenant, agent)
      child = new_run(tenant, agent, %{parent_run_id: parent.id, depth: 1})

      s = summary(child.id)

      assert s.agent.name == agent.name
      assert s.agent.max_steps == 10
      assert s.parent_run_id == parent.id
      assert s.depth == 1
    end
  end

  describe "collapsing" do
    test "consecutive identical calls collapse into one entry with a range",
         %{tenant: tenant, agent: agent} do
      run = new_run(tenant, agent)
      llm_request(run, 1, ["search_docs"])
      for step <- 1..6, do: tool_pair(run, step, "search_docs", %{"q" => "x"}, "0 results")

      s = summary(run.id)

      assert [entry] = s.timeline
      assert entry.count == 6
      assert entry.step == "1-6"
      # The range is addressable — both ends are real sequence numbers.
      assert [first, last] = entry.seq
      assert first < last
    end

    test "output stays bounded as the run grows", %{tenant: tenant, agent: agent} do
      run = new_run(tenant, agent)
      llm_request(run, 1, ["a"])

      # Alternate tools so nothing collapses, forcing the elision path.
      for step <- 1..60 do
        tool = if rem(step, 2) == 0, do: "tool_a", else: "tool_b"
        tool_pair(run, step, tool, %{"n" => step}, "ok")
      end

      s = summary(run.id)

      assert s.counters.tool_calls == 60
      assert length(s.timeline) <= 20

      marker = Enum.find(s.timeline, &Map.has_key?(&1, :elided))
      assert marker.elided > 0
      assert marker.calls > 0
      # Elided is not discarded — the range says where to look.
      assert [lo, hi] = marker.seq
      assert lo < hi
    end

    test "encoded size stays bounded regardless of run length",
         %{tenant: tenant, agent: agent} do
      # The whole point of the summary. A 200-step run holds megabytes of
      # events; if the summary grew with it, it would be useless on exactly
      # the runs worth summarizing.
      sizes =
        for steps <- [5, 200] do
          run = new_run(tenant, agent)

          for step <- 1..steps do
            llm_request(run, step, ["search_docs", "escalate"])
            tool = Enum.random(["search_docs", "escalate", "read_file"])
            tool_pair(run, step, tool, %{"query" => "q#{step}"}, String.duplicate("data ", 200))
          end

          run.id |> summary() |> Jason.encode!() |> byte_size()
        end

      [small, large] = sizes

      assert large < 8_000, "200-step summary was #{large} bytes"
      # Growth is sub-linear by a wide margin: 40x the events, well under 5x
      # the output.
      assert large < small * 5
    end

    test "a differing result class breaks a collapse group", %{tenant: tenant, agent: agent} do
      run = new_run(tenant, agent)
      tool_pair(run, 1, "fetch", %{}, "ok")
      tool_pair(run, 2, "fetch", %{}, "boom", true)
      tool_pair(run, 3, "fetch", %{}, "ok")

      s = summary(run.id)

      assert length(s.timeline) == 3
    end
  end

  describe "signals" do
    test "detects a loop", %{tenant: tenant, agent: agent} do
      run = new_run(tenant, agent)
      for step <- 1..8, do: tool_pair(run, step, "search_docs", %{"q" => "x"}, "0 results")

      assert %{severity: "high"} = sig = signal(summary(run.id), "loop")
      assert sig.detail =~ "8 consecutive calls to search_docs"
    end

    test "detects a consistently failing tool", %{tenant: tenant, agent: agent} do
      run = new_run(tenant, agent)
      for step <- 1..3, do: tool_pair(run, step, "escalate", %{}, "connection refused", true)

      assert sig = signal(summary(run.id), "tool_failing")
      assert sig.detail =~ "escalate failed on all 3 calls"
    end

    test "a tool that sometimes succeeds is not flagged as failing",
         %{tenant: tenant, agent: agent} do
      run = new_run(tenant, agent)
      tool_pair(run, 1, "flaky", %{}, "boom", true)
      tool_pair(run, 2, "flaky", %{}, "boom", true)
      tool_pair(run, 3, "flaky", %{}, "worked")

      refute signal(summary(run.id), "tool_failing")
    end

    test "detects a tool no worker offered", %{tenant: tenant, agent: agent} do
      run = new_run(tenant, agent)
      llm_request(run, 1, ["search_docs", "escalate"])
      tool_pair(run, 1, "send_email", %{}, "ok")

      assert sig = signal(summary(run.id), "unknown_tool")
      assert sig.detail =~ "send_email"
    end

    test "stays silent about unknown tools when none were recorded",
         %{tenant: tenant, agent: agent} do
      # Runs predating the `tools` field must not produce false positives.
      run = new_run(tenant, agent)
      llm_request(run, 1, [])
      tool_pair(run, 1, "send_email", %{}, "ok")

      refute signal(summary(run.id), "unknown_tool")
    end

    test "detects tools offered but never used", %{tenant: tenant, agent: agent} do
      run = new_run(tenant, agent)
      llm_request(run, 1, ["search_docs", "escalate"])
      append(run, Events.run_completed(%{"output" => "I cannot help"}))
      {:ok, run} = Runs.update_run(run, %{status: "completed"})

      assert sig = signal(summary(run.id), "no_tool_use")
      assert sig.detail =~ "2 tools were available"
    end

    test "detects hitting the step ceiling", %{tenant: tenant, agent: agent} do
      run = new_run(tenant, agent)
      for step <- 1..10, do: llm_request(run, step, ["a"])

      append(
        run,
        Events.run_failed(%{
          "error" => "Max steps (10) exceeded",
          "error_class" => "validation",
          "error_code" => "max_steps",
          "retry_decision" => "terminal"
        })
      )

      {:ok, run} = Runs.update_run(run, %{status: "failed"})

      s = summary(run.id)
      assert signal(s, "max_steps")
      assert s.reason == "max_steps_exceeded"
    end

    test "detects a call that never returned", %{tenant: tenant, agent: agent} do
      run = new_run(tenant, agent)

      append(
        run,
        Events.tool_call(%{
          "tool_call_id" => "orphan",
          "name" => "slow_tool",
          "arguments" => %{},
          "step" => 1
        })
      )

      s = summary(run.id)
      assert sig = signal(s, "unreturned_call")
      assert sig.detail =~ "never produced a result"

      [entry] = s.timeline
      assert entry.result =~ "did not return"
    end

    test "detects a retry storm", %{tenant: tenant, agent: agent} do
      run = new_run(tenant, agent)

      for attempt <- 1..3 do
        append(
          run,
          Events.retry(%{
            "error" => "timeout",
            "attempt" => attempt,
            "delay_ms" => 100,
            "step" => 2,
            "error_class" => "transient",
            "error_code" => "timeout",
            "retry_decision" => "retry"
          })
        )
      end

      assert sig = signal(summary(run.id), "retry_storm")
      assert sig.detail =~ "3 retries at step 2"
    end

    test "detects a run parked on a question", %{tenant: tenant, agent: agent} do
      run = new_run(tenant, agent)

      append(
        run,
        Events.build("waiting_for_user", %{
          "question" => "7pm or 8pm?",
          "tool_call_id" => "ask_1",
          "step" => 1
        })
      )

      {:ok, run} = Runs.update_run(run, %{status: "waiting"})

      s = summary(run.id)
      assert signal(s, "parked_unanswered")
      assert s.reason == "parked"
    end
  end

  describe "excluded content" do
    test "does not leak message arrays or system prompts", %{tenant: tenant, agent: agent} do
      run = new_run(tenant, agent)

      append(
        run,
        Events.llm_request(%{
          "step" => 1,
          "message_count" => 1,
          "messages" => [%{"role" => "user", "content" => "SECRET_MESSAGE_BODY"}],
          "system_prompt" => "SECRET_SYSTEM_PROMPT",
          "model" => "claude-sonnet-5",
          "tools" => ["search_docs"]
        })
      )

      encoded = run.id |> summary() |> Jason.encode!()

      refute encoded =~ "SECRET_MESSAGE_BODY"
      refute encoded =~ "SECRET_SYSTEM_PROMPT"
    end

    test "truncates long tool results", %{tenant: tenant, agent: agent} do
      run = new_run(tenant, agent)
      tool_pair(run, 1, "read_file", %{}, String.duplicate("x", 5_000))

      [entry] = summary(run.id).timeline

      assert entry.result =~ "truncated"
      assert byte_size(entry.result) < 200
    end
  end
end
