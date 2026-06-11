defmodule VutuvWeb.DevDocHTML do
  @moduledoc false
  use VutuvWeb, :html

  embed_templates("../templates/dev_doc/*")

  def nav_class(true = _active),
    do:
      "text-slate-900 underline decoration-brand-500 decoration-2 underline-offset-8 dark:text-slate-100"

  def nav_class(false = _active), do: "text-brand-600 hover:text-brand-700"
end
