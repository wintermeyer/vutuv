defmodule VutuvWeb.ServiceWorkerHTML do
  @moduledoc false
  use VutuvWeb, :html

  embed_templates("../templates/service_worker/*")
end
