defmodule VutuvWeb do
  @moduledoc false

  def model do
    quote do
      use Ecto.Schema

      import Ecto, only: [assoc: 2, build_assoc: 2, build_assoc: 3]
      import Ecto.Changeset
      import Ecto.Query, only: [from: 1, from: 2]
    end
  end

  def controller do
    quote do
      use Phoenix.Controller,
        formats: [:html, :json],
        layouts: [html: {VutuvWeb.LayoutHTML, :app}]

      alias Vutuv.Repo
      import Ecto, only: [assoc: 2, build_assoc: 2, build_assoc: 3]
      import Ecto.Query, only: [from: 1, from: 2]

      use Phoenix.VerifiedRoutes,
        endpoint: VutuvWeb.Endpoint,
        router: VutuvWeb.Router,
        statics: ~w(assets fonts images favicon.ico)

      use Gettext, backend: VutuvWeb.Gettext
    end
  end

  def html do
    quote do
      use Phoenix.Component

      import Phoenix.HTML
      use PhoenixHTMLHelpers

      import Phoenix.Controller, only: [get_csrf_token: 0]

      use Phoenix.VerifiedRoutes,
        endpoint: VutuvWeb.Endpoint,
        router: VutuvWeb.Router,
        statics: ~w(assets fonts images favicon.ico)

      # Local template rendering: dispatches to embed_templates-generated functions
      defp render(template, assigns) when is_binary(template) do
        func = template |> String.trim_trailing(".html") |> String.to_existing_atom()
        apply(__MODULE__, func, [Map.new(assigns)])
      end

      import VutuvWeb.ErrorHelpers
      use Gettext, backend: VutuvWeb.Gettext
      import VutuvWeb.CurrencyHelpers
    end
  end

  def router do
    quote do
      use Phoenix.Router
    end
  end

  def channel do
    quote do
      use Phoenix.Channel

      alias Vutuv.Repo
      import Ecto.Query, only: [from: 1, from: 2]
      use Gettext, backend: VutuvWeb.Gettext
    end
  end

  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
