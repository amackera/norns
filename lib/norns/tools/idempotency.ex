defmodule Norns.Tools.Idempotency do
  @moduledoc false

  alias Norns.Tools.Tool

  @type context :: %{
          run_id: pos_integer(),
          step: pos_integer(),
          tool_call_id: String.t(),
          tool_name: String.t(),
          side_effect?: boolean(),
          idempotency_key: String.t() | nil
        }

  def context(%{id: run_id} = run, step, %{"id" => tool_call_id, "name" => tool_name} = tc, %Tool{} = tool) do
    arguments = tc["arguments"] || tc["input"] || %{}
    side_effect? = side_effecting?(tool, arguments)
    gard_id = Map.get(run, :gard_id)

    %{
      run_id: run_id,
      step: step,
      tool_call_id: tool_call_id,
      tool_name: tool_name,
      side_effect?: side_effect?,
      idempotency_key:
        if(side_effect?, do: key(run_id, step, tool_call_id, tool_name, gard_id), else: nil)
    }
  end

  # The same (tool, args) in two different gards is genuinely two different
  # operations — without the gard in the key, crash recovery could skip a call
  # in gard B because gard A already recorded a result for it. No-gard runs
  # keep the historical key shape, so keys stored before gards exist still
  # match on replay.
  def key(run_id, step, tool_call_id, tool_name, gard_id \\ nil)

  def key(run_id, step, tool_call_id, tool_name, nil) do
    "run:#{run_id}:step:#{step}:tool:#{tool_call_id}:name:#{tool_name}"
  end

  def key(run_id, step, tool_call_id, tool_name, gard_id) do
    "run:#{run_id}:step:#{step}:tool:#{tool_call_id}:name:#{tool_name}:gard:#{gard_id}"
  end

  def side_effecting?(%Tool{name: "http_request"}, %{"method" => method}) do
    String.upcase(method) == "POST"
  end

  def side_effecting?(%Tool{name: "http_request"}, _input), do: false
  def side_effecting?(%Tool{source: {:remote, _}}, _input), do: true
  def side_effecting?(%Tool{side_effect?: side_effect?}, _input), do: side_effect?
end
