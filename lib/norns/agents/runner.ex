defmodule Norns.Agents.Runner do
  @moduledoc """
  Synchronous agent execution. Takes an agent, input, and tenant,
  runs the LLM call, and records everything as a Run with events.
  """

  alias Norns.Runs
  alias Norns.LLM
  alias Norns.Runtime.{Errors, Events, ErrorPolicy}

  def execute(%{id: agent_id, tenant_id: tenant_id} = agent, input, tenant) do
    api_key = tenant.api_keys["anthropic"] || ""

    case create_run(agent, input) do
      {:ok, run} ->
        with {:ok, _} <- append(run, Events.run_started()),
             {:ok, run} <- Runs.update_run(run, %{status: "running"}),
             {:ok, _} <- append(run, Events.llm_request(%{"step" => 1, "message_count" => 1})),
             {:ok, response} <- call_llm(api_key, agent, input),
             {:ok, _} <- log_llm_response(run, response),
             {:ok, run} <- Runs.update_run(run, %{status: "completed", output: response, failure_metadata: %{}}),
             {:ok, _} <- append(run, Events.run_completed(%{"output" => response})) do
          {:ok, run}
        else
          {:error, reason} ->
            handle_failure(run, agent_id, tenant_id, reason)
            {:error, reason}
        end

      {:error, reason} ->
        handle_failure(nil, agent_id, tenant_id, reason)
        {:error, reason}
    end
  end

  defp create_run(agent, input) do
    Runs.create_run(%{
      agent_id: agent.id,
      tenant_id: agent.tenant_id,
      trigger_type: "external",
      input: %{"user_message" => input},
      status: "pending"
    })
  end

  defp call_llm(api_key, agent, input) do
    model_config = agent.model_config || %{}
    opts = if model_config["max_tokens"], do: [max_tokens: model_config["max_tokens"]], else: []

    LLM.complete(api_key, agent.model, agent.system_prompt, input, opts)
  end

  defp log_llm_response(run, response) do
    append(
      run,
      Events.llm_response(%{
        "content" => [%{"type" => "text", "text" => response}],
        "stop_reason" => "end_turn",
        "usage" => %{},
        "step" => 1
      })
    )
  end

  defp handle_failure(run, agent_id, tenant_id, reason) do
    require Logger

    error = Errors.classify(reason)
    decision = ErrorPolicy.decision(error, 0)
    failure_payload = Errors.to_metadata(error) |> Map.put("retry_decision", decision.retry_decision)

    if run do
      append(run, Events.run_failed(failure_payload))
      Runs.update_run(run, %{
        status: "failed",
        failure_metadata: Map.put(failure_payload, "schema_version", Norns.Runtime.EventValidator.schema_version())
      })
    end

    Logger.error(
      "Agent run failed: agent_id=#{agent_id} tenant_id=#{tenant_id} reason=#{inspect(reason)}"
    )
  end

  defp append(run, {:ok, event}), do: Runs.append_event(run, event)
  defp append(_run, {:error, reason}), do: {:error, reason}
end
