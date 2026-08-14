defmodule NornsWeb.CacheBodyReader do
  @moduledoc """
  Body reader for `Plug.Parsers` that stashes the raw request body on webhook
  ingest requests before parsing consumes it. Provider signatures (GitHub,
  Stripe, Slack) are HMACs over the bytes on the wire — parsed params can't
  reproduce them.

  Only `/api/v1/hooks/:token` deliveries are cached; every other request
  keeps the default zero-copy behaviour.
  """

  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} -> {:ok, body, maybe_cache(conn, body)}
      {:more, body, conn} -> {:more, body, maybe_cache(conn, body)}
      other -> other
    end
  end

  # Ingest is POST /api/v1/hooks/<token> — exactly four path segments.
  # Management routes (POST /api/v1/hooks) don't match and aren't cached.
  defp maybe_cache(%Plug.Conn{path_info: ["api", "v1", "hooks", _token]} = conn, body) do
    cached = conn.assigns[:raw_body] || []
    Plug.Conn.assign(conn, :raw_body, cached ++ [body])
  end

  defp maybe_cache(conn, _body), do: conn
end
