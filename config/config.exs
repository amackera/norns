import Config

config :norns,
  ecto_repos: [Norns.Repo]

config :norns, Norns.Repo,
  migration_timestamps: [type: :utc_datetime_usec]

config :norns, Oban,
  repo: Norns.Repo,
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7}
  ],
  queues: [default: 10, agents: 5]

config :norns,
  generators: [timestamp_type: :utc_datetime_usec]


config :norns, Norns.LLM, module: Norns.LLM.Anthropic

config :norns, NornsWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [json: NornsWeb.ErrorJSON], layout: false],
  pubsub_server: Norns.PubSub,
  live_view: [signing_salt: "norns_lv_salt"]

config :tailwind,
  version: "4.1.12",
  norns: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

config :phoenix, :json_library, Jason

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

import_config "#{config_env()}.exs"
