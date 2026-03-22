defmodule NornsWeb.JSON do
  @moduledoc "Serialization helpers for API responses."

  def agent(agent) do
    %{
      id: agent.id,
      name: agent.name,
      purpose: agent.purpose,
      status: agent.status,
      system_prompt: agent.system_prompt,
      model: agent.model,
      max_steps: agent.max_steps,
      inserted_at: agent.inserted_at,
      updated_at: agent.updated_at
    }
  end

  def run(run) do
    %{
      id: run.id,
      agent_id: run.agent_id,
      status: run.status,
      trigger_type: run.trigger_type,
      input: run.input,
      output: run.output,
      inserted_at: run.inserted_at,
      updated_at: run.updated_at
    }
  end

  def run_event(event) do
    %{
      id: event.id,
      sequence: event.sequence,
      event_type: event.event_type,
      payload: event.payload,
      source: event.source,
      inserted_at: event.inserted_at
    }
  end
end
