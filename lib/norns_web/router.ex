defmodule NornsWeb.Router do
  use NornsWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
    plug NornsWeb.Plugs.Auth
  end

  scope "/api/v1", NornsWeb do
    pipe_through :api

    resources "/agents", AgentController, only: [:create, :index, :show] do
      post "/start", AgentController, :start
      delete "/stop", AgentController, :stop
      get "/status", AgentController, :status
      post "/messages", AgentController, :send_message
      get "/runs", AgentController, :runs
    end

    get "/runs/:id", RunController, :show
    get "/runs/:id/events", RunController, :events
  end
end
