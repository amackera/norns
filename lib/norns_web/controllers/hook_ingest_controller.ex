defmodule NornsWeb.HookIngestController do
  @moduledoc """
  The public webhook ingress: `POST /api/v1/hooks/:token`.

  The token in the URL is the credential. Status codes are chosen for
  provider retry semantics: 202 on success, 409 when the mapped conversation
  is busy (providers retry non-2xx, which is exactly what we want), 401 on a
  failed signature, 404 for unknown-or-disabled tokens (indistinguishable on
  purpose).
  """

  use NornsWeb, :controller

  alias Norns.Hooks

  def create(conn, %{"token" => token}) do
    payload = Map.drop(conn.body_params, ["token"])
    raw_body = IO.iodata_to_binary(conn.assigns[:raw_body] || [])

    case Hooks.handle_delivery(token, payload, raw_body, conn.req_headers) do
      {:ok, run_id} ->
        conn |> put_status(202) |> json(%{status: "accepted", run_id: run_id})

      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "not found"})

      {:error, :busy} ->
        conn |> put_status(409) |> json(%{error: "agent is busy — retry later"})

      {:error, reason} when reason in ["missing_signature", "invalid_signature", "stale_timestamp"] ->
        conn |> put_status(401) |> json(%{error: reason})

      {:error, reason} ->
        conn |> put_status(500) |> json(%{error: inspect(reason)})
    end
  end
end
