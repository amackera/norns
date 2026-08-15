defmodule NornsWeb.WorkerController do
  use NornsWeb, :controller

  alias Norns.Workers.WorkerRegistry

  @doc """
  Workers currently holding a connection for this tenant.

  The liveness half of the deployment picture: an operator (or provisioner)
  can see that a container is running, but only this endpoint says whether
  the worker inside it reached Norns and registered. A deployment that is
  "running" in Docker and absent here is crash-looping or can't connect.
  """
  def index(conn, _params) do
    tenant = conn.assigns.current_tenant
    json(conn, %{data: WorkerRegistry.connected_workers(tenant.id)})
  end
end
