defmodule VutuvWeb.PageHTML do
  @moduledoc false
  use VutuvWeb, :html

  # The sign-up form's email-type radios: the values and their order come from
  # the schema, the labels from the same helper the email pages use, so all
  # three renderings of Personal/Work/Other stay in step.
  import VutuvWeb.EmailHTML, only: [email_type_label: 1]

  alias Vutuv.Accounts.Email

  embed_templates("../templates/page/*")
end
