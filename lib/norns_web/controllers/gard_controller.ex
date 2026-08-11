defmodule NornsWeb.GardController do
  use NornsWeb, :controller

  alias Norns.Gards

  def index(conn, _params) do
    tenant = conn.assigns.current_tenant
    gards = Gards.list_gards(tenant.id)
    json(conn, %{data: Enum.map(gards, &NornsWeb.JSON.gard/1)})
  end

  def create(conn, params) do
    tenant = conn.assigns.current_tenant
    attrs = Map.put(params, "tenant_id", tenant.id)

    case Gards.create_gard(attrs) do
      {:ok, gard} ->
        # The claim token is returned exactly once, here — it's the secret the
        # provisioner hands to the worker. List/show never include it.
        data = gard |> NornsWeb.JSON.gard() |> Map.put(:claim_token, gard.claim_token)
        conn |> put_status(201) |> json(%{data: data})

      {:error, changeset} ->
        conn |> put_status(422) |> json(%{error: format_errors(changeset)})
    end
  end

  def show(conn, %{"id" => id}) do
    tenant = conn.assigns.current_tenant

    with {:ok, gard} <- fetch_gard(tenant.id, id) do
      data =
        gard
        |> NornsWeb.JSON.gard()
        |> Map.put(:ports, Enum.map(Gards.list_ports(gard.id), &NornsWeb.JSON.gard_port/1))

      json(conn, %{data: data})
    end
  end

  def update(conn, %{"id" => id} = params) do
    tenant = conn.assigns.current_tenant

    with {:ok, gard} <- fetch_gard(tenant.id, id) do
      attrs = Map.drop(params, ["id", "tenant_id", "status", "claim_token"])

      case Gards.update_gard(gard, attrs) do
        {:ok, gard} ->
          json(conn, %{data: NornsWeb.JSON.gard(gard)})

        {:error, changeset} ->
          conn |> put_status(422) |> json(%{error: format_errors(changeset)})
      end
    end
  end

  def delete(conn, %{"id" => id} = params) do
    tenant = conn.assigns.current_tenant
    force = Map.get(params, "force") in [true, "true"]

    with {:ok, gard} <- fetch_gard(tenant.id, id) do
      case Gards.destroy(tenant.id, gard.id, force: force) do
        :ok ->
          send_resp(conn, 204, "")

        {:error, :active_run} ->
          conn
          |> put_status(409)
          |> json(%{error: "gard has an active run — pass force=true to destroy anyway"})

        {:error, _} ->
          conn |> put_status(404) |> json(%{error: "not found"})
      end
    end
  end

  def ports(conn, %{"gard_id" => id}) do
    tenant = conn.assigns.current_tenant

    with {:ok, gard} <- fetch_gard(tenant.id, id) do
      json(conn, %{data: Enum.map(Gards.list_ports(gard.id), &NornsWeb.JSON.gard_port/1)})
    end
  end

  defp fetch_gard(tenant_id, id) do
    case Gards.get_gard(tenant_id, id) do
      nil -> {:error, :not_found}
      gard -> {:ok, gard}
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
