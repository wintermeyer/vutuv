defmodule VutuvWeb.ErrorJSON do
  @moduledoc false

  def render("error.json", _assigns) do
    %{errors: "not found"}
  end

  def render(template, _assigns) do
    %{errors: %{detail: Phoenix.Controller.status_message_from_template(template)}}
  end
end
