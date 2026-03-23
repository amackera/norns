defmodule NornsWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :norns

  @session_options [
    store: :cookie,
    key: "_norns_key",
    signing_salt: "norns_salt",
    same_site: "Lax"
  ]

  socket "/socket", NornsWeb.AgentSocket, websocket: true
  socket "/worker", NornsWeb.WorkerSocket, websocket: true
  socket "/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]]

  plug Plug.Static,
    at: "/",
    from: :norns,
    gzip: false,
    only: NornsWeb.static_paths()

  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.Session, @session_options
  plug NornsWeb.Router
end
