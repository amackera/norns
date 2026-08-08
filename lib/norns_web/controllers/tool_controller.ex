defmodule NornsWeb.ToolController do
  use NornsWeb, :controller

  alias Norns.Tools.Catalog

  @doc """
  Tools an agent in this tenant can currently call.

  Answers the question you have to settle before writing an agent definition:
  will the tools I name actually be there? Worker tools exist only while their
  worker is connected, so `meta` reports how many are connected and whether an
  LLM worker is available — an empty list means something different in each
  case.
  """
  def index(conn, _params) do
    tenant = conn.assigns.current_tenant

    json(conn, %{
      data: tenant.id |> Catalog.for_tenant() |> Enum.map(&NornsWeb.JSON.tool/1),
      meta: Catalog.availability(tenant.id)
    })
  end
end
