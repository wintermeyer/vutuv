defmodule VutuvWeb.RecruiterSubscriptionHTML do
  @moduledoc false
  use VutuvWeb, :html
  import VutuvWeb.UserHelpers

  embed_templates("../templates/recruiter_subscription/*")
end
