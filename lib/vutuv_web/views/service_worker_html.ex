defmodule VutuvWeb.ServiceWorkerHTML do
  @moduledoc false
  use VutuvWeb, :html

  alias VutuvWeb.ErrorHTML

  embed_templates("../templates/service_worker/*")
end
