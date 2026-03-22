defmodule NornsWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :norns

  socket "/socket", NornsWeb.AgentSocket, websocket: true
  socket "/worker", NornsWeb.WorkerSocket, websocket: true

  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Phoenix.json_library()

  plug NornsWeb.Router
end
