defmodule NornsWeb.Layouts do
  use NornsWeb, :html
  import Plug.CSRFProtection, only: [get_csrf_token: 0]

  embed_templates "layouts/*"
end
