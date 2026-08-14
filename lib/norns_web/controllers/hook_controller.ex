defmodule NornsWeb.HookController do
  use NornsWeb, :controller

  alias Norns.Hooks

  def index(conn, _params) do
    tenant = conn.assigns.current_tenant
    json(conn, %{data: Enum.map(Hooks.list_hooks(tenant.id), &NornsWeb.JSON.hook/1)})
  end

  def create(conn, params) do
    tenant = conn.assigns.current_tenant
    attrs = params |> Map.drop(["token"]) |> Map.put("tenant_id", tenant.id)

    case Hooks.create_hook(attrs) do
      {:ok, hook} ->
        conn |> put_status(201) |> json(%{data: NornsWeb.JSON.hook(hook)})

      {:error, changeset} ->
        conn |> put_status(422) |> json(%{error: format_errors(changeset)})
    end
  end

  def show(conn, %{"id" => id}) do
    tenant = conn.assigns.current_tenant

    with {:ok, hook} <- fetch_hook(tenant.id, id) do
      json(conn, %{data: NornsWeb.JSON.hook(hook)})
    end
  end

  def update(conn, %{"id" => id} = params) do
    tenant = conn.assigns.current_tenant

    with {:ok, hook} <- fetch_hook(tenant.id, id) do
      attrs = Map.drop(params, ["id", "tenant_id", "agent_id", "token"])

      case Hooks.update_hook(hook, attrs) do
        {:ok, hook} ->
          json(conn, %{data: NornsWeb.JSON.hook(hook)})

        {:error, changeset} ->
          conn |> put_status(422) |> json(%{error: format_errors(changeset)})
      end
    end
  end

  def delete(conn, %{"id" => id}) do
    tenant = conn.assigns.current_tenant

    with {:ok, hook} <- fetch_hook(tenant.id, id) do
      {:ok, _} = Hooks.delete_hook(hook)
      send_resp(conn, 204, "")
    end
  end

  defp fetch_hook(tenant_id, id) do
    case Hooks.get_hook(tenant_id, id) do
      nil -> {:error, :not_found}
      hook -> {:ok, hook}
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
