defmodule NornsWeb.TriggerController do
  use NornsWeb, :controller

  alias Norns.Triggers

  def index(conn, params) do
    tenant = conn.assigns.current_tenant

    triggers =
      case Map.get(params, "agent_id") do
        nil -> Triggers.list_triggers(tenant.id)
        agent_id -> Triggers.list_triggers(tenant.id, agent_id)
      end

    json(conn, %{data: Enum.map(triggers, &NornsWeb.JSON.trigger/1)})
  end

  def create(conn, params) do
    tenant = conn.assigns.current_tenant
    attrs = Map.put(params, "tenant_id", tenant.id)

    case Triggers.create_trigger(attrs) do
      {:ok, trigger} ->
        conn |> put_status(201) |> json(%{data: NornsWeb.JSON.trigger(trigger)})

      {:error, changeset} ->
        conn |> put_status(422) |> json(%{error: format_errors(changeset)})
    end
  end

  def show(conn, %{"id" => id}) do
    tenant = conn.assigns.current_tenant

    with {:ok, trigger} <- fetch_trigger(tenant.id, id) do
      json(conn, %{data: NornsWeb.JSON.trigger(trigger)})
    end
  end

  def update(conn, %{"id" => id} = params) do
    tenant = conn.assigns.current_tenant

    with {:ok, trigger} <- fetch_trigger(tenant.id, id) do
      attrs = Map.drop(params, ["id", "tenant_id", "agent_id", "last_fired_at"])

      case Triggers.update_trigger(trigger, attrs) do
        {:ok, trigger} ->
          json(conn, %{data: NornsWeb.JSON.trigger(trigger)})

        {:error, changeset} ->
          conn |> put_status(422) |> json(%{error: format_errors(changeset)})
      end
    end
  end

  def delete(conn, %{"id" => id}) do
    tenant = conn.assigns.current_tenant

    with {:ok, trigger} <- fetch_trigger(tenant.id, id) do
      {:ok, _} = Triggers.delete_trigger(trigger)
      send_resp(conn, 204, "")
    end
  end

  # Fire outside the schedule — the builder loop's "test it now" without
  # waiting for Friday. Doesn't consume the next scheduled firing.
  def fire(conn, %{"trigger_id" => id}) do
    tenant = conn.assigns.current_tenant

    with {:ok, trigger} <- fetch_trigger(tenant.id, id) do
      case Triggers.fire(trigger) do
        {:ok, run_id} -> conn |> put_status(202) |> json(%{status: "accepted", run_id: run_id})
        {:error, :busy} -> conn |> put_status(409) |> json(%{error: "agent is busy"})
        {:error, reason} -> conn |> put_status(500) |> json(%{error: inspect(reason)})
      end
    end
  end

  defp fetch_trigger(tenant_id, id) do
    case Triggers.get_trigger(tenant_id, id) do
      nil -> {:error, :not_found}
      trigger -> {:ok, trigger}
    end
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  # Override action/2 to handle {:error, :not_found} from with clauses
  def action(conn, _) do
    args = [conn, conn.params]

    case apply(__MODULE__, action_name(conn), args) do
      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "not found"})

      conn ->
        conn
    end
  end
end
