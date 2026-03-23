defmodule Norns.Agents.Process do
  @moduledoc """
  Durable agent GenServer. Runs an LLM-tool loop, persisting every step
  as a RunEvent so it can resume after a crash.

  Supports interrupt/resume via the `ask_user` tool — the agent pauses,
  surfaces a question, and waits for the user to respond.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Norns.{Agents, LLM, Runs, Tenants}
  alias Norns.Agents.AgentDef
  alias Norns.Tools.{Executor, Tool}

  @max_retries 3
  @max_rate_limit_retries 10
  @rate_limit_base_delay_ms 15_000

  # -- Public API --

  def start_link(opts) do
    agent_id = Keyword.fetch!(opts, :agent_id)
    tenant_id = Keyword.fetch!(opts, :tenant_id)
    name = {:via, Registry, {Norns.AgentRegistry, {tenant_id, agent_id}}}
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def send_message(pid, content) when is_binary(content) do
    GenServer.cast(pid, {:send_message, content})
  end

  def get_state(pid) do
    GenServer.call(pid, :get_state)
  end

  # -- Callbacks --

  @impl true
  def init(opts) do
    agent_id = Keyword.fetch!(opts, :agent_id)
    tenant_id = Keyword.fetch!(opts, :tenant_id)
    resume_run_id = Keyword.get(opts, :resume_run_id)

    agent = Agents.get_agent!(agent_id)
    tenant = Tenants.get_tenant!(tenant_id)
    api_key = tenant.api_keys["anthropic"] || ""

    agent_def =
      Keyword.get_lazy(opts, :agent_def, fn ->
        tools = Keyword.get(opts, :tools, [])
        max_steps = Keyword.get(opts, :max_steps)

        def_opts = [tools: tools]
        base_def = AgentDef.from_agent(agent, def_opts)

        if max_steps, do: %{base_def | max_steps: max_steps}, else: base_def
      end)

    state = %{
      agent_id: agent_id,
      tenant_id: tenant_id,
      agent: agent,
      api_key: api_key,
      agent_def: agent_def,
      messages: [],
      step: 0,
      retry_count: 0,
      run: nil,
      status: :idle,
      # Interrupt state: when ask_user is called, we store the pending tool call
      # so we can deliver the user's response as a tool_result
      pending_ask: nil
    }

    if resume_run_id do
      {:ok, state, {:continue, {:resume, resume_run_id}}}
    else
      {:ok, state}
    end
  end

  @impl true
  def handle_cast({:send_message, content}, %{status: :idle} = state) do
    {:ok, run} =
      Runs.create_run(%{
        agent_id: state.agent_id,
        tenant_id: state.tenant_id,
        trigger_type: "message",
        input: %{"user_message" => content},
        status: "pending"
      })

    Runs.append_event(run, %{event_type: "agent_started", source: "system"})
    {:ok, run} = Runs.update_run(run, %{status: "running"})

    messages = state.messages ++ [%{role: "user", content: content}]
    state = %{state | run: run, messages: messages, step: 0, retry_count: 0, status: :running}

    broadcast(state, :agent_started, %{run_id: run.id})
    {:noreply, state, {:continue, :llm_loop}}
  end

  # Resume from waiting — user responded to ask_user
  def handle_cast({:send_message, content}, %{status: :waiting, pending_ask: pending} = state)
      when not is_nil(pending) do
    # Log the user's response
    Runs.append_event(state.run, %{
      event_type: "user_response",
      source: "user",
      payload: %{"content" => content, "tool_use_id" => pending.tool_use_id, "step" => state.step}
    })

    # Build the tool_result for the ask_user call
    ask_result = %{
      "type" => "tool_result",
      "tool_use_id" => pending.tool_use_id,
      "content" => content
    }

    # Build complete tool results: any already-executed tool results + the ask_user result
    all_tool_results = pending.other_results ++ [ask_result]

    # Append as user message and continue the loop
    messages = state.messages ++ [%{role: "user", content: all_tool_results}]
    state = %{state | messages: messages, status: :running, pending_ask: nil}

    Runs.update_run(state.run, %{status: "running"})
    broadcast(state, :agent_resumed, %{run_id: state.run.id})

    state = maybe_checkpoint(state, :tool_result)
    {:noreply, state, {:continue, :llm_loop}}
  end

  def handle_cast({:send_message, _content}, state) do
    Logger.warning("Agent #{state.agent_id} received message while #{state.status}, ignoring")
    {:noreply, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    reply = %{
      agent_id: state.agent_id,
      run_id: state.run && state.run.id,
      status: state.status,
      step: state.step,
      message_count: length(state.messages),
      pending_question: state.pending_ask && state.pending_ask.question
    }

    {:reply, reply, state}
  end

  @impl true
  def handle_continue(:llm_loop, state) do
    max_steps = state.agent_def.max_steps

    if state.step >= max_steps do
      {:noreply, complete_with_error(state, "Max steps (#{max_steps}) exceeded")}
    else
      state = %{state | step: state.step + 1}

      Runs.append_event(state.run, %{
        event_type: "llm_request",
        source: "system",
        payload: %{"step" => state.step, "message_count" => length(state.messages)}
      })

      api_tools = Enum.map(state.agent_def.tools, &Tool.to_api_format/1)
      opts = if api_tools == [], do: [], else: [tools: api_tools]

      messages_for_llm = compact_messages(state.messages)

      system_prompt = state.agent_def.system_prompt <> "\n\nCurrent date: #{Date.utc_today()}."

      case LLM.chat(state.api_key, state.agent_def.model, system_prompt, messages_for_llm, opts) do
        {:ok, response} ->
          state = %{state | retry_count: 0}
          handle_llm_response(state, response)

        {:error, reason} ->
          handle_llm_error(state, reason)
      end
    end
  end

  def handle_continue({:resume, run_id}, state) do
    case rebuild_state(run_id, state) do
      {:ok, resumed_state} ->
        broadcast(resumed_state, :agent_resumed, %{run_id: run_id})
        {:noreply, resumed_state, {:continue, :llm_loop}}

      {:error, reason} ->
        Logger.error("Failed to resume run #{run_id}: #{inspect(reason)}")
        {:stop, {:resume_failed, reason}, state}
    end
  end

  def handle_continue({:execute_tools, tool_use_blocks}, state) do
    # Separate ask_user from regular tools
    {ask_blocks, regular_blocks} =
      Enum.split_with(tool_use_blocks, fn b -> b["name"] == "ask_user" end)

    # Execute regular tools first
    Enum.each(regular_blocks, fn block ->
      Runs.append_event(state.run, %{
        event_type: "tool_call",
        source: "system",
        payload: %{
          "tool_use_id" => block["id"],
          "name" => block["name"],
          "input" => block["input"],
          "step" => state.step
        }
      })

      broadcast(state, :tool_call, %{name: block["name"], input: block["input"]})
    end)

    regular_results =
      if regular_blocks != [] do
        results = Executor.execute_all(regular_blocks, state.agent_def.tools)

        Enum.each(results, fn result ->
          Runs.append_event(state.run, %{
            event_type: "tool_result",
            source: "system",
            payload: %{
              "tool_use_id" => result["tool_use_id"],
              "content" => result["content"],
              "is_error" => Map.get(result, "is_error", false),
              "step" => state.step
            }
          })

          broadcast(state, :tool_result, %{
            tool_use_id: result["tool_use_id"],
            content: result["content"]
          })
        end)

        results
      else
        []
      end

    # Handle ask_user — take the first one (LLM shouldn't call multiple, but just in case)
    case ask_blocks do
      [ask_block | _] ->
        question = get_in(ask_block, ["input", "question"]) || "What would you like me to do?"

        Runs.append_event(state.run, %{
          event_type: "tool_call",
          source: "system",
          payload: %{
            "tool_use_id" => ask_block["id"],
            "name" => "ask_user",
            "input" => ask_block["input"],
            "step" => state.step
          }
        })

        Runs.append_event(state.run, %{
          event_type: "waiting_for_user",
          source: "system",
          payload: %{"question" => question, "tool_use_id" => ask_block["id"], "step" => state.step}
        })

        Runs.update_run(state.run, %{status: "waiting"})

        broadcast(state, :waiting, %{question: question, tool_use_id: ask_block["id"]})

        state = %{
          state
          | status: :waiting,
            pending_ask: %{
              tool_use_id: ask_block["id"],
              question: question,
              other_results: regular_results
            }
        }

        {:noreply, state}

      [] ->
        # No ask_user — normal flow: append results and continue
        messages = state.messages ++ [%{role: "user", content: regular_results}]
        state = %{state | messages: messages}
        state = maybe_checkpoint(state, :tool_result)
        {:noreply, state, {:continue, :llm_loop}}
    end
  end

  @impl true
  def handle_info(:retry_llm, state) do
    {:noreply, state, {:continue, :llm_loop}}
  end

  # -- Internal --

  defp handle_llm_response(state, response) do
    Runs.append_event(state.run, %{
      event_type: "llm_response",
      source: "system",
      payload: %{
        "content" => response.content,
        "stop_reason" => response.stop_reason,
        "usage" => %{
          "input_tokens" => response.usage.input_tokens,
          "output_tokens" => response.usage.output_tokens
        },
        "step" => state.step
      }
    })

    messages = state.messages ++ [%{role: "assistant", content: response.content}]
    state = %{state | messages: messages}

    state = maybe_checkpoint(state, :llm_response)

    broadcast(state, :llm_response, %{
      step: state.step,
      stop_reason: response.stop_reason,
      content: response.content
    })

    case response.stop_reason do
      "end_turn" ->
        {:noreply, complete_successfully(state, response.content)}

      "tool_use" ->
        tool_use_blocks =
          Enum.filter(response.content, fn c -> c["type"] == "tool_use" end)

        {:noreply, state, {:continue, {:execute_tools, tool_use_blocks}}}

      other ->
        Logger.info("Unknown stop_reason #{inspect(other)}, treating as end_turn")
        {:noreply, complete_successfully(state, response.content)}
    end
  end

  defp handle_llm_error(state, reason) do
    {max_retries, delay} = retry_params(reason, state.retry_count)

    if state.agent_def.on_failure == :retry_last_step and state.retry_count < max_retries do
      retry_count = state.retry_count + 1

      Logger.warning("LLM call failed (attempt #{retry_count}/#{max_retries}), retrying in #{delay}ms: #{inspect(reason)}")

      Runs.append_event(state.run, %{
        event_type: "retry",
        source: "system",
        payload: %{
          "error" => inspect(reason),
          "attempt" => retry_count,
          "delay_ms" => delay,
          "step" => state.step
        }
      })

      state = %{state | step: state.step - 1, retry_count: retry_count}
      Process.send_after(self(), :retry_llm, delay)
      {:noreply, state}
    else
      Logger.error("LLM call failed: #{inspect(reason)}")
      {:noreply, complete_with_error(state, "LLM error: #{inspect(reason)}")}
    end
  end

  defp retry_params(reason, retry_count) do
    if rate_limit_error?(reason) do
      {@max_rate_limit_retries, @rate_limit_base_delay_ms * (retry_count + 1)}
    else
      {@max_retries, 1000 * Integer.pow(2, retry_count)}
    end
  end

  defp rate_limit_error?({429, _}), do: true
  defp rate_limit_error?(_), do: false

  @tool_result_cap 200

  defp compact_messages(messages) when length(messages) <= 4, do: messages

  defp compact_messages(messages) do
    {old, recent} = Enum.split(messages, length(messages) - 2)
    Enum.map(old, &compact_message/1) ++ recent
  end

  defp compact_message(%{role: "user", content: content} = msg) when is_list(content) do
    compacted =
      Enum.map(content, fn
        %{"type" => "tool_result", "content" => c} = block when is_binary(c) and byte_size(c) > @tool_result_cap ->
          truncated = String.slice(c, 0, @tool_result_cap) <> "...(truncated)"
          %{block | "content" => truncated}

        other ->
          other
      end)

    %{msg | content: compacted}
  end

  defp compact_message(msg), do: msg

  defp complete_successfully(state, content) do
    text =
      content
      |> Enum.find_value(fn
        %{"type" => "text", "text" => t} -> t
        _ -> nil
      end) || ""

    Runs.append_event(state.run, %{
      event_type: "agent_completed",
      source: "system",
      payload: %{"output" => text}
    })

    {:ok, run} = Runs.update_run(state.run, %{status: "completed", output: text})
    broadcast(state, :completed, %{output: text})

    %{state | run: run, status: :idle, pending_ask: nil}
  end

  defp complete_with_error(state, reason) do
    Runs.append_event(state.run, %{
      event_type: "agent_error",
      source: "system",
      payload: %{"error" => reason}
    })

    {:ok, run} = Runs.update_run(state.run, %{status: "failed"})
    broadcast(state, :error, %{error: reason})

    %{state | run: run, status: :idle, pending_ask: nil}
  end

  defp maybe_checkpoint(state, context) do
    should_checkpoint =
      case state.agent_def.checkpoint_policy do
        :every_step -> true
        :on_tool_call -> context == :tool_result
        :manual -> false
      end

    if should_checkpoint do
      Runs.append_event(state.run, %{
        event_type: "checkpoint",
        source: "system",
        payload: %{
          "messages" => state.messages,
          "step" => state.step
        }
      })
    end

    state
  end

  defp broadcast(state, event, payload) do
    Phoenix.PubSub.broadcast(
      Norns.PubSub,
      "agent:#{state.agent_id}",
      {event, Map.put(payload, :agent_id, state.agent_id)}
    )
  end

  # -- State Reconstruction --

  @doc "Rebuild agent state from the event log for a given run."
  def rebuild_state(run_id, base_state) do
    run = Runs.get_run!(run_id)
    events = Runs.list_events(run_id)

    if events == [] do
      {:error, :no_events}
    else
      {messages, step, pending_ask} = replay_from_events(events)

      status = if pending_ask, do: :waiting, else: :running

      {:ok,
       %{
         base_state
         | run: run,
           messages: messages,
           step: step,
           status: status,
           pending_ask: pending_ask
       }}
    end
  end

  defp replay_from_events(events) do
    checkpoint =
      events
      |> Enum.reverse()
      |> Enum.find(fn e -> e.event_type == "checkpoint" end)

    case checkpoint do
      %{payload: %{"messages" => messages, "step" => step}} ->
        post_checkpoint =
          Enum.drop_while(events, fn e -> e.sequence <= checkpoint.sequence end)

        replay_events_onto(messages, step, nil, post_checkpoint)

      nil ->
        replay_events_onto([], 0, nil, events)
    end
  end

  defp replay_events_onto(messages, step, pending_ask, events) do
    Enum.reduce(events, {messages, step, pending_ask}, fn event, {msgs, s, pa} ->
      case event.event_type do
        "llm_response" ->
          content = event.payload["content"]
          {msgs ++ [%{role: "assistant", content: content}], event.payload["step"] || s, nil}

        "tool_result" ->
          tool_result = %{
            "type" => "tool_result",
            "tool_use_id" => event.payload["tool_use_id"],
            "content" => event.payload["content"]
          }

          tool_result =
            if event.payload["is_error"],
              do: Map.put(tool_result, "is_error", true),
              else: tool_result

          case List.last(msgs) do
            %{role: "user", content: content} when is_list(content) ->
              updated = List.replace_at(msgs, -1, %{role: "user", content: content ++ [tool_result]})
              {updated, s, pa}

            _ ->
              {msgs ++ [%{role: "user", content: [tool_result]}], s, pa}
          end

        "waiting_for_user" ->
          pa = %{
            tool_use_id: event.payload["tool_use_id"],
            question: event.payload["question"],
            other_results: []
          }

          {msgs, s, pa}

        "user_response" ->
          # User responded — the pending ask is resolved
          {msgs, s, nil}

        "checkpoint" ->
          {event.payload["messages"], event.payload["step"], nil}

        _ ->
          {msgs, s, pa}
      end
    end)
  end
end
