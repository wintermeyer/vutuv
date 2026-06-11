defmodule VutuvWeb.DevWebhookHTML do
  @moduledoc false
  use VutuvWeb, :html

  embed_templates("../templates/dev_webhook/*")
end
