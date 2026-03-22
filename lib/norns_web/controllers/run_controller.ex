defmodule NornsWeb.RunController do
  use NornsWeb, :controller

  alias Norns.Runs

  def show(conn, %{"id" => id}) do
    tenant = conn.assigns.current_tenant

    with {:ok, run} <- fetch_run(id, tenant.id) do
      json(conn, %{data: NornsWeb.JSON.run(run)})
    end
  end

  def events(conn, %{"id" => id}) do
    tenant = conn.assigns.current_tenant

    with {:ok, _run} <- fetch_run(id, tenant.id) do
      events = Runs.list_events(String.to_integer(id))
      json(conn, %{data: Enum.map(events, &NornsWeb.JSON.run_event/1)})
    end
  end

  defp fetch_run(id, tenant_id) do
    run = Runs.get_run!(id)

    if run.tenant_id == tenant_id do
      {:ok, run}
    else
      {:error, :not_found}
    end
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
  end

  def action(conn, _) do
    case apply(__MODULE__, action_name(conn), [conn, conn.params]) do
      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "not found"})

      conn ->
        conn
    end
  end
end
