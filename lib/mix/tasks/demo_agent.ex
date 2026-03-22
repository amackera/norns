defmodule Mix.Tasks.Demo.Agent do
  @moduledoc """
  Run a research agent with real LLM and tools.

  Requires ANTHROPIC_API_KEY to be set.

      mix demo.agent "What are the main features of Elixir 1.18?"
      mix demo.agent "Find the current weather in Toronto"
      mix demo.agent                  # uses a default query
  """

  use Mix.Task

  @shortdoc "Run a research agent with real LLM + tools"

  @default_query "What are the most interesting recent developments in the Elixir programming language?"

  @system_prompt """
  You are a research assistant. When asked a question, use your tools to gather information,
  then synthesize a clear, concise answer. Use the http_request tool to fetch web pages and
  the web_search tool to find information. Be thorough but concise.
  """

  def run(args) do
    Mix.Task.run("app.start")

    query = Enum.join(args, " ") |> String.trim()
    query = if query == "", do: @default_query, else: query

    api_key = Application.get_env(:norns, :default_anthropic_api_key)

    if is_nil(api_key) or api_key == "" do
      Mix.shell().error("""
      ANTHROPIC_API_KEY is not set.

      Set it in your environment:
        export ANTHROPIC_API_KEY=sk-ant-...

      Or pass it via docker compose:
        docker compose run --rm -e ANTHROPIC_API_KEY=sk-ant-... -e POSTGRES_HOST=db app mix demo.agent "your query"
      """)

      System.halt(1)
    end

    alias Norns.{Agents, Runs, Tenants}
    alias Norns.Agents.Registry
    alias Norns.Tools.{Http, Shell, WebSearch}

    Mix.shell().info("""

    ┌─────────────────────────────────┐
    │  Norns Research Agent           │
    │  Real LLM + real tool calls     │
    └─────────────────────────────────┘
    """)

    # Setup
    step("Setting up tenant and agent...")
    {:ok, tenant} = Tenants.create_tenant(%{
      name: "Demo",
      slug: "demo-agent-#{System.unique_integer([:positive])}",
      api_keys: %{"anthropic" => api_key}
    })

    {:ok, agent} = Agents.create_agent(%{
      tenant_id: tenant.id,
      name: "researcher-#{System.unique_integer([:positive])}",
      system_prompt: @system_prompt,
      status: "idle",
      model: "claude-haiku-4-5-20251001",
      model_config: %{"on_failure" => "retry_last_step"}
    })

    tools = [Http.__tool__(), WebSearch.__tool__(), Shell.__tool__()]
    info("  Agent: #{agent.name}")
    info("  Model: #{agent.model}")
    info("  Tools: #{Enum.map_join(tools, ", ", & &1.name)}")

    # Subscribe to events
    Phoenix.PubSub.subscribe(Norns.PubSub, "agent:#{agent.id}")

    # Start and send
    step("Query: #{query}")
    {:ok, _pid} = Registry.start_agent(agent.id, tenant.id, tools: tools)
    Registry.send_message(tenant.id, agent.id, query)

    # Stream events
    step("Agent is working...")
    run_id = stream_events(agent.id)

    # Print results
    if run_id do
      run = Runs.get_run!(run_id)
      events = Runs.list_events(run_id)

      info("")
      step("Result:")
      info("")
      info(run.output || "(no output)")
      info("")

      llm_calls = Enum.count(events, &(&1.event_type == "llm_request"))
      tool_calls = Enum.count(events, &(&1.event_type == "tool_call"))
      info("  #{llm_calls} LLM calls, #{tool_calls} tool calls, #{length(events)} total events")
      info("  Run ID: #{run_id}, Status: #{run.status}")
    end

    info("")
  end

  defp stream_events(agent_id) do
    stream_events_loop(agent_id, nil)
  end

  defp stream_events_loop(agent_id, run_id) do
    receive do
      {:agent_started, %{run_id: rid}} ->
        stream_events_loop(agent_id, rid)

      {:llm_response, %{stop_reason: "tool_use", content: content}} ->
        tool_names =
          content
          |> Enum.filter(fn c -> c["type"] == "tool_use" end)
          |> Enum.map_join(", ", fn c -> c["name"] end)

        info("  LLM → tool call: #{tool_names}")
        stream_events_loop(agent_id, run_id)

      {:llm_response, %{stop_reason: "end_turn"}} ->
        info("  LLM → final answer")
        stream_events_loop(agent_id, run_id)

      {:tool_call, %{name: name, input: input}} ->
        input_summary = input |> inspect() |> String.slice(0, 80)
        info("  Executing: #{name}(#{input_summary})")
        stream_events_loop(agent_id, run_id)

      {:tool_result, %{tool_use_id: _id, content: content}} ->
        preview = content |> String.slice(0, 100) |> String.replace("\n", " ")
        info("  Result: #{preview}...")
        stream_events_loop(agent_id, run_id)

      {:completed, %{output: _output}} ->
        run_id

      {:error, %{error: reason}} ->
        Mix.shell().error("  Agent error: #{reason}")
        run_id

      _other ->
        stream_events_loop(agent_id, run_id)
    after
      120_000 ->
        Mix.shell().error("  Timeout — agent did not complete within 2 minutes")
        run_id
    end
  end

  defp step(msg), do: Mix.shell().info(">> #{msg}")
  defp info(msg), do: Mix.shell().info(msg)
end
